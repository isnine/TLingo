#if os(macOS)
    import Foundation

    @MainActor
    final class RealtimeLaneRuntime {
        private struct RecognitionMetadata {
            let id: UUID
            let text: String
            let offset: TimeInterval
            let duration: TimeInterval
            let speakerID: String?
        }

        let configuration: RealtimeLaneConfiguration
        private(set) var snapshot: RealtimeLaneSnapshot
        var onChange: (() -> Void)?

        private let sourceLanguage: SourceLanguageOption
        private let targetLanguage: TargetLanguageOption
        private let audioSource: RealtimeHistoryAudioSource?
        private let displayMode: () -> RealtimeCaptionDisplayMode
        private let elapsed: () -> TimeInterval
        private let now: () -> Date
        private let translationExecutor: (RealtimeTextTranslationRequest) async throws -> ModelExecutionResult
        private let recognitionBaseline: RealtimeRecognitionSnapshot?
        private var transcriptAccumulator = RealtimeTranscriptAccumulator()
        private var translationState = RealtimeIncrementalTranslationState()
        private var historyBuilder = RealtimeHistorySessionBuilder()
        private var sourceOnlyHistory: [RealtimeHistoryTrackSegment] = []
        private var recognitionSegments: [RealtimeRecognitionSegment] = []
        private var pendingRecognitionSegment: RealtimeRecognitionSegment?
        private var pairedHistoryIDsByRecognitionPart: [String: UUID] = [:]
        private var finalTranslationTask: Task<Void, Never>?
        private var partialTranslationTask: Task<Void, Never>?
        private var queuedFinalRequests: [RealtimeTextTranslationRequest] = []
        private var latestPartialRequest: RealtimeTextTranslationRequest?
        private var currentEventOffset: TimeInterval
        private var trackUpdatedAt: Date?
        private var latencyContextsByTranslationKey: [String: (
            recognitionLatency: TimeInterval,
            recognizedAt: Date
        )] = [:]
        private var isTranslationDisabled = false
        private var hasSuccessfulTranslation = false

        init(
            configuration: RealtimeLaneConfiguration,
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption,
            audioSource: RealtimeHistoryAudioSource? = nil,
            startedOffset: TimeInterval,
            recognitionBaseline: RealtimeRecognitionSnapshot? = nil,
            displayMode: @escaping () -> RealtimeCaptionDisplayMode,
            elapsed: @escaping () -> TimeInterval,
            now: @escaping () -> Date = Date.init,
            translationExecutor: ((RealtimeTextTranslationRequest) async throws -> ModelExecutionResult)? = nil
        ) {
            self.configuration = configuration
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.audioSource = audioSource
            self.displayMode = displayMode
            self.elapsed = elapsed
            self.now = now
            self.recognitionBaseline = recognitionBaseline
            self.translationExecutor = translationExecutor ?? RealtimeTranslationService.translate
            currentEventOffset = startedOffset
            snapshot = RealtimeLaneSnapshot(
                configuration: configuration,
                phase: .loading,
                startedOffset: startedOffset
            )
            historyBuilder.start(
                at: Date(timeIntervalSinceReferenceDate: 0),
                requestID: configuration.id
            )
        }

        func markListening() {
            snapshot.phase = .listening
            publish()
        }

        func markRecognizing() {
            snapshot.phase = .recognizing
            publish()
        }

        func receiveRecognition(_ result: RealtimeRecognitionResult) {
            guard let result = resultAfterActivation(result) else { return }
            let recognizedAt = now()
            let capturedAudioOffset = elapsed()
            trackUpdatedAt = recognizedAt
            currentEventOffset = max(snapshot.startedOffset, result.audioOffset ?? elapsed())
            if let recognitionSnapshot = result.snapshot {
                recognitionSegments = recognitionSnapshot.stableSegments
                pendingRecognitionSegment = recognitionSnapshot.pendingSegment
            }
            snapshot.sourceText = transcriptAccumulator.append(result, afterLongSilence: false)
            snapshot.phase = .recognizing
            updateRecognitionLatency(capturedAudioOffset: capturedAudioOffset)

            if !configuration.translationProvider.performsTranslation {
                syncIndependentSourceHistory()
                refreshSourceOnlyPresentation()
                return
            }

            translationState.updateSources(from: transcriptAccumulator)
            scheduleTranslation(latencyContext: latestTranslationLatencyContext(
                recognizedAt: recognizedAt,
                capturedAudioOffset: capturedAudioOffset,
                fallbackEndOffset: result.audioOffset
            ))
            syncApplePresentation()
        }

        /// Live recognition latency: how far the captured audio clock is ahead of the newest recognized text.
        private func updateRecognitionLatency(capturedAudioOffset: TimeInterval) {
            guard audioSource != .importedAudio,
                  let end = (pendingRecognitionSegment ?? recognitionSegments.last)?.endOffset
            else { return }
            let latency = RealtimeLaneLatency(
                recognitionLatency: capturedAudioOffset - end,
                translationLatency: snapshot.latency?.translationMilliseconds.map { TimeInterval($0) / 1000 }
            )
            snapshot.latency = latency
        }

        func setPaused(_ isPaused: Bool) {
            snapshot.phase = isPaused ? .paused : .listening
            publish()
        }

        func refreshPresentation() {
            if !configuration.translationProvider.performsTranslation {
                refreshSourceOnlyPresentation()
            } else {
                syncApplePresentation()
            }
        }

        func fail(_ error: Error) {
            snapshot.phase = .failed
            snapshot.errorMessage = (error as NSError).localizedDescription
            snapshot.endedOffset = elapsed()
            snapshot.latency = nil
            trackUpdatedAt = now()
            cancelTranslationWork()
            publish()
        }

        func stop() async {
            transcriptAccumulator.commitPartial()
            if !configuration.translationProvider.performsTranslation {
                syncIndependentSourceHistory()
                refreshSourceOnlyPresentation()
            } else {
                translationState.updateSources(from: transcriptAccumulator)
                let requests = translationState.makeFinalTranslationRequests(
                    provider: configuration.translationProvider,
                    sourceLanguage: sourceLanguage,
                    source: sourceLanguage.localeLanguage,
                    targetLanguage: targetLanguage
                )
                queuedFinalRequests.append(contentsOf: requests)
                startFinalTranslationTaskIfNeeded()
                let partialTask = partialTranslationTask
                partialTranslationTask?.cancel()
                partialTranslationTask = nil
                latestPartialRequest = nil
                await partialTask?.value
                await finalTranslationTask?.value
                syncApplePresentation()
            }
            snapshot.phase = snapshot.errorMessage == nil ? .stopped : .failed
            snapshot.endedOffset = elapsed()
            snapshot.latency = nil
            trackUpdatedAt = now()
            publish()
        }

        func trackSnapshot() -> RealtimeHistoryTrack {
            let segments: [RealtimeHistoryTrackSegment]
            if !configuration.translationProvider.performsTranslation {
                segments = sourceOnlyHistory
            } else {
                var recognitionMetadata = Dictionary(
                    grouping: structuredRecognitionMetadata(),
                    by: { Self.normalizedSourceKey($0.text) }
                )
                segments = historyBuilder.segments.map { segment in
                    let key = Self.normalizedSourceKey(segment.sourceText)
                    let metadata = recognitionMetadata[key]?.first
                    recognitionMetadata[key] = recognitionMetadata[key].map {
                        Array($0.dropFirst())
                    }
                    return RealtimeHistoryTrackSegment(
                        id: metadata?.id ?? segment.id,
                        offset: metadata?.offset ?? segment.offset + snapshot.startedOffset,
                        duration: metadata?.duration ?? 0.5,
                        speakerID: metadata?.speakerID,
                        sourceText: segment.sourceText,
                        translatedText: segment.translatedText,
                        relation: .paired
                    )
                }
            }
            return RealtimeHistoryTrack(
                id: configuration.id,
                audioSource: audioSource,
                startedOffset: snapshot.startedOffset,
                endedOffset: snapshot.endedOffset,
                recognitionModelID: configuration.recognitionModel.id,
                recognitionModelDisplayName: configuration.recognitionModel.title,
                translationProviderID: configuration.translationProvider.rawValue,
                translationProviderDisplayName: configuration.translationProvider.title,
                segments: segments,
                updatedAt: trackUpdatedAt
            )
        }

        static func shouldDisableTranslation(
            after error: Error,
            hasSuccessfulTranslation: Bool
        ) -> Bool {
            !hasSuccessfulTranslation && AppleTranslationErrorFormatter.isLanguagePackMissing(error)
        }
    }

    @MainActor
    private extension RealtimeLaneRuntime {
        private func scheduleTranslation(
            latencyContext: (
                source: String,
                recognitionLatency: TimeInterval,
                recognizedAt: Date
            )?
        ) {
            guard !isTranslationDisabled else { return }
            if languagesMatch {
                translationState.applySameLanguageTranslation()
                syncApplePresentation()
                return
            }

            let finalRequests = translationState.makeFinalTranslationRequests(
                provider: configuration.translationProvider,
                sourceLanguage: sourceLanguage,
                source: sourceLanguage.localeLanguage,
                targetLanguage: targetLanguage
            )
            if let latencyContext,
               let request = finalRequests.last(where: { $0.translationText == latencyContext.source })
            {
                latencyContextsByTranslationKey[request.cacheKey] = (
                    recognitionLatency: latencyContext.recognitionLatency,
                    recognizedAt: latencyContext.recognizedAt
                )
            }
            queuedFinalRequests.append(contentsOf: finalRequests)
            startFinalTranslationTaskIfNeeded()

            latestPartialRequest = translationState.makePartialTranslationRequest(
                provider: configuration.translationProvider,
                sourceLanguage: sourceLanguage,
                source: sourceLanguage.localeLanguage,
                targetLanguage: targetLanguage
            )
            startPartialTranslationTaskIfNeeded()
        }

        private var languagesMatch: Bool {
            guard let source = sourceLanguage.localeLanguage else { return false }
            return RealtimeLanguageMatcher.matches(source, targetLanguage.localeLanguage)
        }

        private func startFinalTranslationTaskIfNeeded() {
            guard finalTranslationTask == nil, !queuedFinalRequests.isEmpty else { return }
            finalTranslationTask = Task { @MainActor [weak self] in
                await self?.processFinalTranslations()
            }
        }

        private func startPartialTranslationTaskIfNeeded() {
            guard partialTranslationTask == nil, latestPartialRequest != nil else { return }
            partialTranslationTask = Task { @MainActor [weak self] in
                await self?.processPartialTranslations()
            }
        }

        private func processFinalTranslations() async {
            while !Task.isCancelled {
                guard !isTranslationDisabled else {
                    finalTranslationTask = nil
                    return
                }
                guard !queuedFinalRequests.isEmpty else {
                    finalTranslationTask = nil
                    return
                }
                let request = queuedFinalRequests.removeFirst()
                do {
                    let result = try await translationExecutor(request)
                    hasSuccessfulTranslation = true
                    snapshot.errorMessage = nil
                    let applied = translationState.applyFinalTranslationSuccess(result, request: request)
                    if applied, let context = latencyContextsByTranslationKey.removeValue(forKey: request.cacheKey) {
                        snapshot.latency = RealtimeLaneLatency(
                            recognitionLatency: context.recognitionLatency,
                            translationLatency: now().timeIntervalSince(context.recognizedAt)
                        )
                    } else {
                        latencyContextsByTranslationKey.removeValue(forKey: request.cacheKey)
                    }
                    syncApplePresentation()
                    if !queuedFinalRequests.isEmpty, request.cadenceInterval > 0 {
                        try await Task.sleep(for: .milliseconds(
                            Int((request.cadenceInterval * 1000).rounded(.up))
                        ))
                    }
                } catch is CancellationError {
                    // The canceller already cleared the handle and may have scheduled a replacement.
                    latencyContextsByTranslationKey.removeValue(forKey: request.cacheKey)
                    return
                } catch {
                    latencyContextsByTranslationKey.removeValue(forKey: request.cacheKey)
                    translationState.finishFinalTranslationRequest(request)
                    handleTranslationFailure(error)
                    syncApplePresentation()
                }
            }
        }

        private func processPartialTranslations() async {
            while !Task.isCancelled {
                guard !isTranslationDisabled else {
                    partialTranslationTask = nil
                    return
                }
                guard let request = latestPartialRequest else {
                    partialTranslationTask = nil
                    return
                }
                latestPartialRequest = nil
                do {
                    if request.cadenceInterval > 0 {
                        try await Task.sleep(for: .milliseconds(
                            Int((request.cadenceInterval * 1000).rounded(.up))
                        ))
                    }
                    let latestRequest = latestPartialRequest ?? request
                    latestPartialRequest = nil
                    let result = try await translationExecutor(latestRequest)
                    hasSuccessfulTranslation = true
                    snapshot.errorMessage = nil
                    _ = translationState.applyPartialTranslationSuccess(result, request: latestRequest)
                    syncApplePresentation()
                } catch is CancellationError {
                    // The canceller already cleared the handle and may have scheduled a replacement.
                    return
                } catch {
                    handleTranslationFailure(error)
                    syncApplePresentation()
                }
            }
        }

        private func handleTranslationFailure(_ error: Error) {
            snapshot.errorMessage = AppleTranslationErrorFormatter.describe(
                error,
                source: sourceLanguage.localeLanguage,
                target: targetLanguage
            )
            snapshot.latency = nil
            guard Self.shouldDisableTranslation(
                after: error,
                hasSuccessfulTranslation: hasSuccessfulTranslation
            ) else { return }
            isTranslationDisabled = true
            queuedFinalRequests.removeAll()
            latestPartialRequest = nil
            translationState.cancelQueuedFinalTranslationRequests()
        }

        private func latestTranslationLatencyContext(
            recognizedAt: Date,
            capturedAudioOffset: TimeInterval,
            fallbackEndOffset: TimeInterval?
        ) -> (
            source: String,
            recognitionLatency: TimeInterval,
            recognizedAt: Date
        )? {
            guard audioSource != .importedAudio,
                  let source = translationState.sourceSegments.last
            else {
                return nil
            }
            let metadata = structuredRecognitionMetadata()
            let key = Self.normalizedSourceKey(source)
            let endOffset = metadata.last(where: {
                Self.normalizedSourceKey($0.text) == key
            }).map { $0.offset + $0.duration } ?? fallbackEndOffset
            guard let endOffset else { return nil }
            return (
                source: source,
                recognitionLatency: max(0, capturedAudioOffset - endOffset),
                recognizedAt: recognizedAt
            )
        }

        private func syncApplePresentation() {
            snapshot.sourceText = transcriptAccumulator.visibleText
            snapshot.translatedText = translationState.translatedText
            snapshot.pendingSourceText = translationState.pendingSourceText
            snapshot.pendingTranslatedText = translationState.pendingTranslatedText
            snapshot.sentencePairs = translationState.sentencePairs
            snapshot.captionLines = RealtimeCaptionDisplay.displayWindow(
                RealtimeCaptionDisplay.resolvedLines(
                    pairs: translationState.sentencePairs,
                    translatedSourceSegments: translationState.sourceSegments,
                    translatedSource: translationState.translationSourceText,
                    translatedText: translationState.translatedText,
                    pendingSource: translationState.pendingSourceText,
                    pendingTranslation: translationState.pendingTranslatedText,
                    sourceText: transcriptAccumulator.visibleText,
                    mode: displayMode()
                ),
                limit: 160
            )
            historyBuilder.sync(
                pairs: translationState.sentencePairs,
                at: Date(timeIntervalSinceReferenceDate: currentEventOffset - snapshot.startedOffset)
            )
            publish()
        }

        private func refreshSourceOnlyPresentation() {
            snapshot.translatedText = ""
            snapshot.pendingSourceText = transcriptAccumulator.partialText
            snapshot.pendingTranslatedText = ""
            snapshot.sentencePairs = []
            var structuredLines = recognitionSegments.map {
                RealtimeCaptionLine(
                    id: "recognition-\($0.id.uuidString)",
                    kind: .source,
                    text: $0.text
                )
            }
            if let pendingRecognitionSegment {
                structuredLines.append(RealtimeCaptionLine(
                    id: "recognition-pending-\(pendingRecognitionSegment.id.uuidString)",
                    kind: .source,
                    text: pendingRecognitionSegment.text,
                    isPending: true
                ))
            }
            snapshot.captionLines = RealtimeCaptionDisplay.displayWindow(
                structuredLines.isEmpty
                    ? RealtimeCaptionDisplay.resolvedLines(
                        pairs: [],
                        translatedSource: transcriptAccumulator.committedText,
                        translatedText: "",
                        pendingSource: transcriptAccumulator.partialText,
                        pendingTranslation: "",
                        sourceText: transcriptAccumulator.visibleText,
                        mode: .sourceOnly
                    )
                    : structuredLines,
                limit: 160
            )
            publish()
        }

        private func syncIndependentSourceHistory() {
            if !recognitionSegments.isEmpty {
                sourceOnlyHistory = recognitionSegments.map {
                    RealtimeHistoryTrackSegment(
                        id: $0.id,
                        offset: $0.startOffset,
                        duration: max(0.5, $0.endOffset - $0.startOffset),
                        speakerID: $0.speakerID,
                        sourceText: $0.text,
                        relation: .sourceOnly
                    )
                }
                return
            }
            syncIndependentHistory(
                texts: historySegments(from: transcriptAccumulator.committedText),
                relation: .sourceOnly,
                into: &sourceOnlyHistory
            )
        }

        private func historySegments(from text: String) -> [String] {
            RealtimeTranscriptSegmenter.segments(from: text).flatMap { segment in
                let words = segment.split(whereSeparator: \.isWhitespace)
                let hasSentenceTerminator = segment.contains { ".!?。！？".contains($0) }
                guard !hasSentenceTerminator, words.count > 24 else { return [segment] }
                return stride(from: 0, to: words.count, by: 24).map { start in
                    words[start ..< min(start + 24, words.count)].joined(separator: " ")
                }
            }
        }

        private func structuredRecognitionMetadata() -> [RecognitionMetadata] {
            recognitionSegments.flatMap { segment in
                let parts = RealtimeTranscriptSegmenter.segments(from: segment.text)
                let texts = parts.isEmpty ? [segment.text] : parts
                let totalWeight = max(1, texts.reduce(0) { $0 + max(1, $1.count) })
                let totalDuration = max(0.5, segment.endOffset - segment.startOffset)
                var offset = segment.startOffset
                return texts.enumerated().map { index, text in
                    let duration = totalDuration * Double(max(1, text.count)) / Double(totalWeight)
                    defer { offset += duration }
                    let key = "\(segment.id.uuidString):\(index)"
                    let id = index == 0
                        ? segment.id
                        : pairedHistoryIDsByRecognitionPart[key, default: UUID()]
                    return RecognitionMetadata(
                        id: id,
                        text: text,
                        offset: offset,
                        duration: duration,
                        speakerID: segment.speakerID
                    )
                }
            }
        }

        private func resultAfterActivation(_ result: RealtimeRecognitionResult) -> RealtimeRecognitionResult? {
            guard let recognitionSnapshot = result.snapshot else { return result }
            if !recognitionSnapshot.stableSegments.isEmpty || recognitionSnapshot.pendingSegment != nil {
                let stableSegments = recognitionSnapshot.stableSegments.filter {
                    $0.startOffset >= snapshot.startedOffset
                }
                let pendingSegment = recognitionSnapshot.pendingSegment.flatMap {
                    $0.startOffset >= snapshot.startedOffset ? $0 : nil
                }
                guard !stableSegments.isEmpty || pendingSegment != nil else { return nil }
                return RealtimeRecognitionResult(
                    snapshot: RealtimeRecognitionSnapshot(
                        stableSegments: stableSegments,
                        pendingSegment: pendingSegment,
                        tokenTimings: recognitionSnapshot.tokenTimings,
                        audioOffset: recognitionSnapshot.audioOffset,
                        isTerminal: recognitionSnapshot.isTerminal
                    ),
                    confidence: result.confidence
                )
            }

            guard let recognitionBaseline else { return result }
            let stableText = Self.suffix(
                after: recognitionBaseline.stableText,
                in: recognitionSnapshot.stableText
            )
            let volatileText: String
            if stableText.isEmpty,
               recognitionSnapshot.stableText == recognitionBaseline.stableText
            {
                volatileText = Self.suffix(
                    after: recognitionBaseline.volatileText,
                    in: recognitionSnapshot.volatileText
                )
            } else {
                volatileText = recognitionSnapshot.volatileText
            }
            guard !stableText.isEmpty || !volatileText.isEmpty else { return nil }
            return RealtimeRecognitionResult(
                snapshot: RealtimeRecognitionSnapshot(
                    stableText: stableText,
                    volatileText: volatileText,
                    tokenTimings: recognitionSnapshot.tokenTimings,
                    audioOffset: recognitionSnapshot.audioOffset,
                    isTerminal: recognitionSnapshot.isTerminal
                ),
                confidence: result.confidence
            )
        }

        private static func suffix(after prefix: String, in text: String) -> String {
            let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else { return text }
            guard text.hasPrefix(prefix) else { return "" }
            return String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func normalizedSourceKey(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }

        private func syncIndependentHistory(
            texts: [String],
            relation: RealtimeHistoryTrackSegmentRelation,
            into segments: inout [RealtimeHistoryTrackSegment]
        ) {
            let existingCount = min(texts.count, segments.count)
            let previousOffset = segments.prefix(existingCount).last?.offset ?? snapshot.startedOffset
            let newCount = max(0, texts.count - existingCount)
            let offsetStep = newCount > 0
                ? max(0.001, (currentEventOffset - previousOffset) / Double(newCount))
                : 0
            segments = texts.enumerated().map { index, text in
                if segments.indices.contains(index) {
                    var segment = segments[index]
                    if relation == .sourceOnly {
                        segment.sourceText = text
                    } else {
                        segment.translatedText = text
                    }
                    return segment
                }
                return RealtimeHistoryTrackSegment(
                    offset: previousOffset + offsetStep * Double(index - existingCount + 1),
                    sourceText: relation == .sourceOnly ? text : "",
                    translatedText: relation == .translationOnly ? text : "",
                    relation: relation
                )
            }
        }

        private func cancelTranslationWork() {
            finalTranslationTask?.cancel()
            partialTranslationTask?.cancel()
            finalTranslationTask = nil
            partialTranslationTask = nil
            queuedFinalRequests.removeAll()
            latestPartialRequest = nil
            latencyContextsByTranslationKey.removeAll()
        }

        private func publish() {
            onChange?()
        }
    }
#endif
