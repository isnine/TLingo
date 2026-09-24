#if os(macOS) && arch(arm64) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
    import AVFoundation
    import Foundation
    import HuggingFace
    import MLXAudioCore
    import MLXAudioSTT

    public enum RealtimeHistoryMOSSProgress: Equatable, Sendable {
        case downloading(fraction: Double)
        case loadingModel
        case preparingAudio
        case transcribing(segments: [RealtimeHistoryTrackSegment])
        case translating(completed: Int, total: Int, segments: [RealtimeHistoryTrackSegment])
    }

    public enum RealtimeHistoryMOSSReconstructorError: LocalizedError, Equatable {
        case recordingUnavailable
        case speechNotRecognized
        case unsupportedLanguage

        public var errorDescription: String? {
            switch self {
            case .recordingUnavailable:
                return String(localized: "No recording is available for the selected audio source.")
            case .speechNotRecognized:
                return String(localized: "No speech was recognized in the selected recording.")
            case .unsupportedLanguage:
                return String(localized: "This history language pair cannot be translated.")
            }
        }
    }

    public actor RealtimeHistoryMOSSReconstructor {
        public static let shared = RealtimeHistoryMOSSReconstructor()
        public static let modelID = "moss-transcribe-diarize"
        public static let modelDisplayName = "MOSS Diarization"
        public static let modelSizeDisplayName = "1.83 GB"

        private static let repositoryID = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
        private static let inferenceChunkDuration: TimeInterval = 300
        private static let modelFilename = "model-00000-of-00001.safetensors"

        private let fileManager: FileManager
        private let cacheURL: URL
        private var downloadTask: Task<Void, Error>?
        public private(set) var currentProgress: RealtimeHistoryMOSSProgress?

        public init(
            cacheURL: URL? = nil,
            fileManager: FileManager = .default
        ) {
            self.fileManager = fileManager
            self.cacheURL = cacheURL ?? fileManager
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RecognitionModels", isDirectory: true)
                .appendingPathComponent(Self.modelID, isDirectory: true)
        }

        public func isModelCached() -> Bool {
            guard let enumerator = fileManager.enumerator(
                at: cacheURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return false
            }
            return enumerator.compactMap { $0 as? URL }.contains {
                $0.lastPathComponent == Self.modelFilename
            }
        }

        public func deleteModel() throws {
            guard fileManager.fileExists(atPath: cacheURL.path) else { return }
            try fileManager.removeItem(at: cacheURL)
        }

        public func ensureModelAvailable() async throws {
            guard !isModelCached() else { return }
            try await downloadModel()
        }

        public func recognizeImportedAudio(
            at url: URL,
            progress: @escaping @MainActor @Sendable (RealtimeHistoryMOSSProgress) -> Void
        ) async throws -> [RealtimeRecognitionSegment] {
            defer { currentProgress = nil }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            try await ensureModelAvailable()
            try Task.checkCancellation()
            let audioFile = try AVAudioFile(forReading: url)
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            let recognized = try Self.transcriptSegments(
                from: await transcribe(url: url, source: .importedAudio, progress: progress),
                source: .importedAudio,
                recordingDuration: duration
            )
            guard !recognized.isEmpty else {
                throw RealtimeHistoryMOSSReconstructorError.speechNotRecognized
            }
            return recognized.map {
                RealtimeRecognitionSegment(
                    id: $0.id,
                    text: $0.text,
                    startOffset: $0.offset,
                    endOffset: $0.offset + $0.duration,
                    speakerID: $0.speakerID,
                    boundaryReason: .terminal
                )
            }
        }

        public func reconstruct(
            session: RealtimeHistorySession,
            source: RealtimeHistoryAudioSource,
            progress: @escaping @MainActor @Sendable (RealtimeHistoryMOSSProgress) -> Void
        ) async throws -> RealtimeHistoryTrack {
            defer { currentProgress = nil }
            guard let recording = session.audioRecordings.first(where: {
                $0.source == source && $0.hasPlayableAudio
            }) else {
                throw RealtimeHistoryMOSSReconstructorError.recordingUnavailable
            }

            let wasCached = isModelCached()
            if !wasCached {
                try await downloadModel()
                try Task.checkCancellation()
            }
            await reportProgress(.loadingModel, callback: progress)
            let duration = RealtimeHistoryAudioTimeline.duration(for: recording)
            let recognized = try Self.transcriptSegments(
                from: await transcribe(recording: recording, progress: progress),
                source: source,
                recordingDuration: duration
            )
            guard !recognized.isEmpty else {
                throw RealtimeHistoryMOSSReconstructorError.speechNotRecognized
            }

            guard let sourceLanguage = SourceLanguageOption.realtimeOption(englishName: session.sourceLanguage),
                  let targetLanguage = TargetLanguageOption.realtimeOption(englishName: session.targetLanguage)
            else {
                throw RealtimeHistoryMOSSReconstructorError.unsupportedLanguage
            }
            let speakersByID = Dictionary(uniqueKeysWithValues: recognized.map { ($0.id, $0.speakerID) })
            let previewSegments = recognized.map {
                RealtimeHistoryTrackSegment(
                    id: $0.id,
                    offset: $0.offset,
                    duration: $0.duration,
                    speakerID: $0.speakerID,
                    sourceText: $0.text,
                    relation: .sourceOnly
                )
            }
            await reportProgress(
                .translating(completed: 0, total: recognized.count, segments: previewSegments),
                callback: progress
            )
            let translated = try await RealtimeHistoryAudioPostProcessor.translateTranscriptSegments(
                recognized.map(\.transcriptSegment),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                translateText: { text in
                    let result = try await AppleTranslationService.shared.translateRealtimeSentencesWithInstalledLanguages(
                        text: text,
                        source: sourceLanguage.localeLanguage,
                        target: targetLanguage.localeLanguage
                    )
                    return try result.response.get()
                },
                onSegmentTranslated: { segment in
                    let completed = recognized.firstIndex(where: { $0.id == segment.id }).map { $0 + 1 } ?? 0
                    await self.reportProgress(
                        .translating(
                            completed: completed,
                            total: recognized.count,
                            segments: previewSegments
                        ),
                        callback: progress
                    )
                }
            )

            return RealtimeHistoryTrack(
                audioSource: source,
                startedOffset: 0,
                endedOffset: duration,
                recognitionModelID: Self.modelID,
                recognitionModelDisplayName: Self.modelDisplayName,
                translationProviderID: ModelConfig.appleTranslateID,
                translationProviderDisplayName: ModelConfig.appleTranslate.displayName,
                segments: translated.map {
                    RealtimeHistoryTrackSegment(
                        id: $0.id,
                        offset: $0.offset,
                        duration: $0.duration,
                        speakerID: speakersByID[$0.id] ?? nil,
                        sourceText: $0.text,
                        translatedText: $0.translatedText,
                        relation: $0.translatedText.isEmpty ? .sourceOnly : .paired
                    )
                },
                updatedAt: Date()
            )
        }

        private func loadedModel() async throws -> any STTGenerationModel {
            try await STT.loadModel(
                modelRepo: Self.repositoryID,
                cache: .init(cacheDirectory: cacheURL)
            )
        }

        private func downloadModel() async throws {
            if downloadTask == nil {
                let cache = HubCache(cacheDirectory: cacheURL)
                currentProgress = .downloading(fraction: 0)
                downloadTask = Task {
                    guard let repositoryID = Repo.ID(rawValue: Self.repositoryID) else {
                        throw STTModelError.invalidRepositoryID(Self.repositoryID)
                    }
                    _ = try await HubClient(cache: cache).downloadSnapshot(
                        of: repositoryID,
                        progressHandler: { downloadProgress in
                            let fraction = min(max(downloadProgress.fractionCompleted, 0), 1)
                            Task { await self.updateDownloadProgress(fraction) }
                        }
                    )
                }
            }

            defer {
                currentProgress = nil
                downloadTask = nil
            }
            try await downloadTask?.value
        }

        private func updateDownloadProgress(_ fraction: Double) {
            currentProgress = .downloading(fraction: fraction)
        }

        private func transcribe(
            recording: RealtimeHistoryAudioRecording,
            progress: @escaping @MainActor @Sendable (RealtimeHistoryMOSSProgress) -> Void
        ) async throws -> [[String: Any]]? {
            let audioURL = try await RealtimeHistoryAudioTimeline.makeTemporaryPCMFile(for: recording)
            defer { try? fileManager.removeItem(at: audioURL) }
            return try await transcribe(url: audioURL, source: recording.source, progress: progress)
        }

        private func transcribe(
            url audioURL: URL,
            source: RealtimeHistoryAudioSource,
            progress: @escaping @MainActor @Sendable (RealtimeHistoryMOSSProgress) -> Void
        ) async throws -> [[String: Any]]? {
            let model = try await loadedModel()
            try Task.checkCancellation()
            await reportProgress(.preparingAudio, callback: progress)
            let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16000)
            let parameters = STTGenerateParameters(
                maxTokens: 5120,
                temperature: 0,
                chunkDuration: Float(Self.inferenceChunkDuration),
                minChunkDuration: 1
            )
            var previewText = ""
            var previewSegmentIDs: [String: UUID] = [:]
            var lastPreviewUpdate = Date.distantPast
            await reportProgress(.transcribing(segments: []), callback: progress)
            for try await event in model.generateStream(audio: audio, generationParameters: parameters) {
                try Task.checkCancellation()
                switch event {
                case let .token(token):
                    previewText += token
                    let now = Date()
                    guard now.timeIntervalSince(lastPreviewUpdate) >= 0.25 else { continue }
                    lastPreviewUpdate = now
                    await reportProgress(
                        .transcribing(
                            segments: Self.streamingTrackSegments(
                                from: previewText,
                                source: source,
                                ids: &previewSegmentIDs
                            )
                        ),
                        callback: progress
                    )
                case .info:
                    continue
                case let .result(output):
                    await reportProgress(
                        .transcribing(
                            segments: Self.streamingTrackSegments(
                                from: output.text,
                                source: source,
                                ids: &previewSegmentIDs
                            )
                        ),
                        callback: progress
                    )
                    return output.segments
                }
            }
            return nil
        }

        private func reportProgress(
            _ progress: RealtimeHistoryMOSSProgress,
            callback: @escaping @MainActor @Sendable (RealtimeHistoryMOSSProgress) -> Void
        ) async {
            currentProgress = progress
            await callback(progress)
        }
    }

    extension RealtimeHistoryMOSSReconstructor {
        struct ParsedSegment: Equatable {
            let id: UUID
            let source: RealtimeHistoryAudioSource
            let offset: TimeInterval
            let duration: TimeInterval
            let speakerID: String?
            let text: String

            var transcriptSegment: RealtimeHistoryTranscriptSegment {
                RealtimeHistoryTranscriptSegment(
                    id: id,
                    source: source,
                    offset: offset,
                    duration: duration,
                    text: text
                )
            }
        }

        static func transcriptSegments(
            from rawSegments: [[String: Any]]?,
            source: RealtimeHistoryAudioSource,
            recordingDuration: TimeInterval
        ) -> [ParsedSegment] {
            (rawSegments ?? []).compactMap { raw in
                guard let start = number(raw["start"]),
                      let end = number(raw["end"]),
                      end >= start,
                      let rawText = raw["text"] as? String
                else {
                    return nil
                }
                let parsed = speakerAndText(
                    from: rawText,
                    explicitSpeakerID: raw["speaker_id"] as? String
                )
                let speaker = parsed.speakerID
                let text = parsed.text
                guard !text.isEmpty else { return nil }
                let speakerID: String?
                if recordingDuration > inferenceChunkDuration, let speaker {
                    speakerID = "P\(Int(start / inferenceChunkDuration) + 1)-\(speaker)"
                } else {
                    speakerID = speaker
                }
                return ParsedSegment(
                    id: UUID(),
                    source: source,
                    offset: start,
                    duration: max(0.5, end - start),
                    speakerID: speakerID,
                    text: text
                )
            }
            .sorted { $0.offset < $1.offset }
        }

        static func streamingTrackSegments(
            from text: String,
            source: RealtimeHistoryAudioSource,
            ids: inout [String: UUID]
        ) -> [RealtimeHistoryTrackSegment] {
            let pattern = #"\[(\d+(?:[\.,]\d+)?)\]\[(S\d+)\](.*?)\[(\d+(?:[\.,]\d+)?)\]"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                return []
            }

            let nsText = text as NSString
            return regex.matches(
                in: text,
                range: NSRange(location: 0, length: nsText.length)
            ).compactMap { match in
                guard match.numberOfRanges == 5,
                      let start = number(nsText.substring(with: match.range(at: 1))),
                      let end = number(nsText.substring(with: match.range(at: 4))),
                      end >= start
                else {
                    return nil
                }
                let speakerID = nsText.substring(with: match.range(at: 2))
                let segmentText = nsText.substring(with: match.range(at: 3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segmentText.isEmpty else { return nil }
                let key = "\(source.rawValue)|\(start)|\(end)|\(speakerID)"
                let id = ids[key] ?? UUID()
                ids[key] = id
                return RealtimeHistoryTrackSegment(
                    id: id,
                    offset: start,
                    duration: max(0.5, end - start),
                    speakerID: speakerID,
                    sourceText: segmentText,
                    relation: .sourceOnly
                )
            }
        }

        private static func number(_ value: Any?) -> Double? {
            if let value = value as? Double {
                return value
            }
            if let value = value as? NSNumber {
                return value.doubleValue
            }
            if let value = value as? String {
                return Double(value.replacingOccurrences(of: ",", with: "."))
            }
            return nil
        }

        private static func speakerAndText(
            from text: String,
            explicitSpeakerID: String?
        ) -> (speakerID: String?, text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let explicitSpeakerID {
                return (
                    explicitSpeakerID,
                    removingSpeakerPrefix(from: trimmed, speakerID: explicitSpeakerID)
                )
            }
            guard trimmed.first == "[",
                  let closingBracket = trimmed.firstIndex(of: "]")
            else {
                return (nil, trimmed)
            }
            let speakerID = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< closingBracket])
            guard speakerID.first == "S", speakerID.dropFirst().allSatisfy(\.isNumber) else {
                return (nil, trimmed)
            }
            return (
                speakerID,
                String(trimmed[trimmed.index(after: closingBracket)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        private static func removingSpeakerPrefix(from text: String, speakerID: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "[\(speakerID)]"
            guard trimmed.hasPrefix(prefix) else { return trimmed }
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
#endif
