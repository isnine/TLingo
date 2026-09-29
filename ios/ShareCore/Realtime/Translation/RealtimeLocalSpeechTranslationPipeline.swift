#if os(iOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    public final class RealtimeLocalSpeechTranslationPipeline: @unchecked Sendable {
        public var onStateChange: ((RealtimeBroadcastState) -> Void)?
        public var onFailure: ((Error) -> Void)?

        private static let audioLevelReportInterval = 8

        private let stateStore: RealtimeBroadcastStateStore
        private let transcriber = RealtimeLiveSpeechTranscriber()
        private let converter = RealtimePCMBufferConverter()
        private let stateLock = NSLock()
        private var activeRecognitionSessionID = UUID()
        private var state: RealtimeBroadcastState
        private var sourceLanguage: SourceLanguageOption?
        private var targetLanguage: TargetLanguageOption?
        private var transcriptAccumulator = RealtimeTranscriptAccumulator()
        private var translationState = RealtimeIncrementalTranslationState()
        private var historySessionBuilder = RealtimeHistorySessionBuilder()
        private var finalTranslationTask: Task<Void, Never>?
        private var partialTranslationTask: Task<Void, Never>?
        private var queuedFinalTranslationRequests: [RealtimeTextTranslationRequest] = []
        private var latestPartialTranslationRequest: RealtimeTextTranslationRequest?
        private var nextPartialTranslationAllowedAt: Date?
        private var isStarted = false
        private var isPaused = false

        public init(
            stateStore: RealtimeBroadcastStateStore = RealtimeBroadcastStateStore() ??
                RealtimeBroadcastStateStore(defaults: .standard),
            sessionID: String = UUID().uuidString
        ) {
            let recognitionSessionID = UUID(uuidString: sessionID) ?? UUID()
            self.stateStore = stateStore
            state = RealtimeBroadcastState(sessionID: recognitionSessionID.uuidString, phase: .idle)
            transcriber.delegate = self
        }

        deinit {
            let transcriber = transcriber
            Task {
                await transcriber.stop()
            }
        }

        public func start(sourceLanguage: SourceLanguageOption, targetLanguage: TargetLanguageOption) async throws {
            Self.log("start requested source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue)")
            if stateLock.withLock({ isStarted }) {
                await stop()
            }
            guard sourceLanguage != .auto else {
                throw RealtimeIPhoneAudioPreflightFailure.missingSourceLanguage
            }
            guard targetLanguage != .appLanguage else {
                throw RealtimeIPhoneAudioPreflightFailure.missingTargetLanguage
            }
            let recognitionSessionID = UUID()
            stateLock.withLock {
                activeRecognitionSessionID = recognitionSessionID
                isStarted = false
            }

            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            transcriptAccumulator.reset()
            cancelTranslationWork()
            translationState.reset()
            historySessionBuilder.start(
                at: Date(),
                requestID: UUID(uuidString: state.sessionID) ?? UUID()
            )
            updateState { state in
                state.phase = .waiting
                state.sourceText = ""
                state.translatedText = ""
                state.translationSourceText = ""
                state.sourceSegments = []
                state.sentencePairs = []
                state.pendingSourceText = ""
                state.pendingTranslatedText = ""
                state.audioSampleCount = 0
                state.audioLevel = nil
                state.errorMessage = nil
                state.stopRequested = false
                state.realtimeHistorySession = nil
            }
            Self.log("start reset \(Self.stateSummary(state))")

            do {
                try await transcriber.start(
                    locale: Locale(identifier: sourceLanguage.rawValue),
                    sessionID: recognitionSessionID
                )
                let startState = stateLock.withLock {
                    guard recognitionSessionID == activeRecognitionSessionID else {
                        return (shouldStart: false, isPaused: false)
                    }
                    isStarted = true
                    return (shouldStart: true, isPaused: isPaused)
                }
                guard startState.shouldStart else {
                    await transcriber.stop()
                    return
                }
                let shouldRemainPaused = startState.isPaused
                transcriber.setPaused(shouldRemainPaused)
                updateState { $0.phase = shouldRemainPaused ? .paused : .broadcasting }
                Self.log("start succeeded paused=\(shouldRemainPaused)")
            } catch {
                guard stateLock.withLock({
                    recognitionSessionID == activeRecognitionSessionID
                }) else {
                    return
                }
                fail(error)
                Self.log("start failed error=\(Self.describe(error))")
                throw error
            }
        }

        public func append(_ sampleBuffer: CMSampleBuffer) {
            guard stateLock.withLock({ isStarted && !isPaused }) else { return }

            let nextCount = incrementAudioSampleCount(level: realtimeAudioLevel(from: sampleBuffer))
            if nextCount == 1 {
                updateState { $0.phase = .broadcasting }
            }

            guard let converter,
                  let pcmBuffer = converter.pcmBuffer(from: sampleBuffer)
            else {
                return
            }
            transcriber.append(pcmBuffer)
        }

        public func setPaused(_ isPaused: Bool) {
            Self.log("pause set paused=\(isPaused)")
            stateLock.withLock {
                self.isPaused = isPaused
                if isPaused {
                    historySessionBuilder.pause()
                } else {
                    historySessionBuilder.resume()
                }
            }
            transcriber.setPaused(isPaused)
            updateState { state in
                guard state.phase != .failed, state.phase != .stopped, state.phase != .stopping else { return }
                state.phase = isPaused ? .paused : .broadcasting
                syncRealtimeHistorySession(into: &state, force: true)
            }
        }

        public func stop() async {
            Self.log("stop requested")
            stateLock.withLock {
                isPaused = true
            }
            transcriber.setPaused(true)
            await transcriber.stop()

            let finalRequests = stateLock.withLock { () -> [RealtimeTextTranslationRequest] in
                guard isStarted, let sourceLanguage, let targetLanguage else { return [] }
                state.sourceText = transcriptAccumulator.commitPartial()
                translationState.updateSources(from: transcriptAccumulator)
                let requests = translationState.makeFinalTranslationRequests(
                    provider: .appleTranslator,
                    sourceLanguage: sourceLanguage,
                    source: sourceLanguage.localeLanguage,
                    targetLanguage: targetLanguage
                )
                applyTranslationStatePresentation(into: &state)
                return requests
            }
            let partialTask = takePartialTranslationTaskForCancellation()
            await partialTask?.value
            enqueueFinalTranslationRequests(finalRequests)
            let finalTask = stateLock.withLock { finalTranslationTask }
            await finalTask?.value

            updateState { state in
                state.phase = state.errorMessage == nil ? .stopped : .failed
                state.stopRequested = false
                syncRealtimeHistorySession(into: &state, force: true)
            }
            stateLock.withLock {
                isStarted = false
                isPaused = false
                activeRecognitionSessionID = UUID()
            }
        }

        private func handleRecognized(_ result: RealtimeRecognitionResult) {
            let scheduled = stateLock.withLock {
                let previousStableLength = translationState.translationSourceText.count
                let previousDisplayedTranslationLength =
                    translationState.translatedText.count + translationState.pendingTranslatedText.count
                let previousPairCount = translationState.sentencePairs.count
                let text = transcriptAccumulator.append(result, afterLongSilence: false)
                translationState.updateSources(from: transcriptAccumulator)
                state.sourceText = text
                applyTranslationStatePresentation(into: &state)
                state.phase = .recognizing
                state.lastUpdatedAt = Date()
                guard let sourceLanguage, let targetLanguage else {
                    return (
                        finalRequests: [] as [RealtimeTextTranslationRequest],
                        partialRequest: nil as RealtimeTextTranslationRequest?,
                        hasPendingSource: false,
                        continuity: Self.continuitySummary(
                            previousStableLength: previousStableLength,
                            previousDisplayedTranslationLength: previousDisplayedTranslationLength,
                            previousPairCount: previousPairCount,
                            state: state
                        )
                    )
                }
                if let source = sourceLanguage.localeLanguage,
                   RealtimeLanguageMatcher.matches(source, targetLanguage.localeLanguage)
                {
                    translationState.applySameLanguageTranslation()
                    applyTranslationStatePresentation(into: &state)
                    return (
                        finalRequests: [] as [RealtimeTextTranslationRequest],
                        partialRequest: nil as RealtimeTextTranslationRequest?,
                        hasPendingSource: false,
                        continuity: Self.continuitySummary(
                            previousStableLength: previousStableLength,
                            previousDisplayedTranslationLength: previousDisplayedTranslationLength,
                            previousPairCount: previousPairCount,
                            state: state
                        )
                    )
                }
                let finalRequests = translationState.makeFinalTranslationRequests(
                    provider: .appleTranslator,
                    sourceLanguage: sourceLanguage,
                    source: sourceLanguage.localeLanguage,
                    targetLanguage: targetLanguage
                )
                let partialRequest = translationState.makePartialTranslationRequest(
                    provider: .appleTranslator,
                    sourceLanguage: sourceLanguage,
                    source: sourceLanguage.localeLanguage,
                    targetLanguage: targetLanguage
                )
                applyTranslationStatePresentation(into: &state)
                return (
                    finalRequests: finalRequests,
                    partialRequest: partialRequest,
                    hasPendingSource: !translationState.pendingSourceText.isEmpty,
                    continuity: Self.continuitySummary(
                        previousStableLength: previousStableLength,
                        previousDisplayedTranslationLength: previousDisplayedTranslationLength,
                        previousPairCount: previousPairCount,
                        state: state
                    )
                )
            }
            saveCurrentState()
            if let continuity = scheduled.continuity {
                Self.log("\(continuity)")
            }

            enqueueFinalTranslationRequests(scheduled.finalRequests)
            if let partialRequest = scheduled.partialRequest {
                schedulePartialTranslation(partialRequest)
            } else if !scheduled.hasPendingSource {
                cancelPartialTranslationWork()
            }
        }

        private func enqueueFinalTranslationRequests(_ requests: [RealtimeTextTranslationRequest]) {
            guard !requests.isEmpty else { return }
            stateLock.lock()
            queuedFinalTranslationRequests.append(contentsOf: requests)
            let queuedCount = queuedFinalTranslationRequests.count
            if finalTranslationTask == nil {
                finalTranslationTask = Task { [weak self] in
                    await self?.processFinalTranslationRequests()
                }
            }
            stateLock.unlock()
            Self.log(
                "final queued added=\(requests.count) queued=\(queuedCount)"
            )
        }

        private func schedulePartialTranslation(_ request: RealtimeTextTranslationRequest) {
            stateLock.lock()
            latestPartialTranslationRequest = request
            if partialTranslationTask == nil {
                partialTranslationTask = Task { [weak self] in
                    await self?.processPartialTranslationRequests()
                }
            }
            stateLock.unlock()
        }

        private func processFinalTranslationRequests() async {
            while !Task.isCancelled {
                let request = stateLock.withLock { () -> RealtimeTextTranslationRequest? in
                    guard !queuedFinalTranslationRequests.isEmpty else {
                        finalTranslationTask = nil
                        return nil
                    }
                    return queuedFinalTranslationRequests.removeFirst()
                }
                guard let request else { return }

                do {
                    updateState { $0.phase = .translating }
                    let result = try await translate(request)
                    applyFinalTranslationResult(result, request: request)
                    let hasQueuedRequests = stateLock.withLock { !queuedFinalTranslationRequests.isEmpty }
                    if hasQueuedRequests, request.cadenceInterval > 0 {
                        try await Task.sleep(for: .milliseconds(Int((request.cadenceInterval * 1000).rounded(.up))))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    stateLock.withLock {
                        translationState.finishFinalTranslationRequest(request)
                        applyTranslationStatePresentation(into: &state)
                    }
                    Self.log("final error=\(Self.describe(error))")
                    fail(error)
                }
            }
        }

        private func processPartialTranslationRequests() async {
            while !Task.isCancelled {
                let initialRequest = stateLock.withLock { () -> RealtimeTextTranslationRequest? in
                    guard let request = latestPartialTranslationRequest else {
                        partialTranslationTask = nil
                        nextPartialTranslationAllowedAt = nil
                        return nil
                    }
                    latestPartialTranslationRequest = nil
                    return request
                }
                guard var request = initialRequest else { return }

                do {
                    let allowedAt = stateLock.withLock { () -> Date in
                        let allowedAt = nextPartialTranslationAllowedAt ?? Date().addingTimeInterval(request.cadenceInterval)
                        nextPartialTranslationAllowedAt = allowedAt
                        return allowedAt
                    }
                    let delay = allowedAt.timeIntervalSinceNow
                    if delay > 0 {
                        try await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
                    }

                    if let newerRequest = stateLock.withLock({
                        let request = latestPartialTranslationRequest
                        latestPartialTranslationRequest = nil
                        return request
                    }) {
                        request = newerRequest
                    }

                    guard !Task.isCancelled else { return }
                    stateLock.withLock {
                        nextPartialTranslationAllowedAt = Date().addingTimeInterval(request.cadenceInterval)
                    }
                    updateState { $0.phase = .translating }
                    let result = try await translate(request)
                    applyPartialTranslationResult(result, request: request)
                } catch is CancellationError {
                    stateLock.withLock {
                        partialTranslationTask = nil
                    }
                    return
                } catch {
                    Self.log("partial error=\(Self.describe(error))")
                    fail(error)
                }
            }
        }

        private func translate(_ request: RealtimeTextTranslationRequest) async throws -> ModelExecutionResult {
            try await RealtimeTranslationService.translate(request)
        }

        private func applyFinalTranslationResult(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) {
            var failure: Error?
            updateState { state in
                guard requestMatchesCurrentConfiguration(request) else {
                    Self.log(
                        """
                        final discarded reason=configChanged \
                        request=\(Self.preview(request.translationText))
                        """
                    )
                    translationState.finishFinalTranslationRequest(request)
                    applyTranslationStatePresentation(into: &state)
                    return
                }

                switch result.response {
                case let .success(text):
                    let applied = translationState.applyFinalTranslationSuccess(result, request: request)
                    applyTranslationStatePresentation(into: &state)
                    state.phase = isPaused ? .paused : .broadcasting
                    state.errorMessage = nil
                    Self.log(
                        """
                        final ok applied=\(applied) src=\(Self.preview(request.translationText)) \
                        -> tr=\(Self.preview(text)) pairs=\(state.sentencePairs.count)/\(state.sourceSegments.count)
                        """
                    )
                case let .failure(error):
                    translationState.finishFinalTranslationRequest(request)
                    applyTranslationStatePresentation(into: &state)
                    state.phase = .failed
                    state.errorMessage = Self.describe(error)
                    Self.log("final failure error=\(Self.describe(error)) \(Self.stateSummary(state))")
                    failure = error
                }
            }
            if let failure {
                onFailure?(failure)
            }
        }

        private func applyPartialTranslationResult(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) {
            var failure: Error?
            updateState { state in
                guard requestMatchesCurrentConfiguration(request) else {
                    Self.log(
                        """
                        partial discarded reason=configChanged \
                        request=\(Self.preview(request.translationText))
                        """
                    )
                    return
                }

                switch result.response {
                case .success:
                    guard translationState.applyPartialTranslationSuccess(result, request: request) else {
                        Self.log(
                            """
                            partial discarded reason=stalePending \
                            request=\(Self.preview(request.translationText))
                            """
                        )
                        return
                    }
                    applyTranslationStatePresentation(into: &state)
                    state.phase = isPaused ? .paused : .broadcasting
                    state.errorMessage = nil
                case let .failure(error):
                    state.phase = .failed
                    state.errorMessage = Self.describe(error)
                    Self.log("partial failure error=\(Self.describe(error)) \(Self.stateSummary(state))")
                    failure = error
                }
            }
            if let failure {
                onFailure?(failure)
            }
        }

        private func cancelTranslationWork() {
            stateLock.withLock {
                finalTranslationTask?.cancel()
                finalTranslationTask = nil
                queuedFinalTranslationRequests.removeAll()
                translationState.cancelQueuedFinalTranslationRequests()
                cancelPartialTranslationWorkLocked()
            }
        }

        private func cancelPartialTranslationWork() {
            stateLock.withLock {
                cancelPartialTranslationWorkLocked()
            }
        }

        private func takePartialTranslationTaskForCancellation() -> Task<Void, Never>? {
            stateLock.withLock {
                let task = partialTranslationTask
                task?.cancel()
                partialTranslationTask = nil
                latestPartialTranslationRequest = nil
                nextPartialTranslationAllowedAt = nil
                return task
            }
        }

        private func cancelPartialTranslationWorkLocked() {
            partialTranslationTask?.cancel()
            partialTranslationTask = nil
            latestPartialTranslationRequest = nil
            nextPartialTranslationAllowedAt = nil
        }

        private func requestMatchesCurrentConfiguration(_ request: RealtimeTextTranslationRequest) -> Bool {
            request.provider == .appleTranslator &&
                request.sourceLanguage == sourceLanguage &&
                request.targetLanguage == targetLanguage
        }

        private func applyTranslationStatePresentation(into state: inout RealtimeBroadcastState) {
            state.translationSourceText = translationState.translationSourceText
            state.sourceSegments = translationState.sourceSegments
            state.sentencePairs = translationState.sentencePairs
            state.pendingSourceText = translationState.pendingSourceText
            state.translatedText = translationState.translatedText
            state.pendingTranslatedText = translationState.pendingTranslatedText
            syncRealtimeHistorySession(into: &state)
        }

        private func syncRealtimeHistorySession(into state: inout RealtimeBroadcastState, force: Bool = false) {
            guard let sourceLanguage, let targetLanguage else {
                state.realtimeHistorySession = nil
                return
            }
            historySessionBuilder.sync(pairs: translationState.sentencePairs)
            if !force, state.realtimeHistorySession?.segments == historySessionBuilder.segments {
                return
            }
            state.realtimeHistorySession = historySessionBuilder.makeSession(
                inputSource: String(localized: "iPhone Audio"),
                sourceLanguage: sourceLanguage.englishName,
                targetLanguage: targetLanguage.englishName,
                modelID: RealtimeTranslationProvider.appleTranslator.modelID,
                modelDisplayName: RealtimeTranslationProvider.appleTranslator.model.displayName
            )
        }

        private func fail(_ error: Error) {
            Self.log("fail error=\(Self.describe(error))")
            updateState { state in
                state.phase = .failed
                state.errorMessage = Self.describe(error)
                state.stopRequested = false
            }
            onFailure?(error)
        }

        private func incrementAudioSampleCount(level: Float?) -> Int {
            stateLock.lock()
            state.audioSampleCount += 1
            let count = state.audioSampleCount
            if count == 1 || count % Self.audioLevelReportInterval == 0 {
                state.audioLevel = level
            }
            state.lastUpdatedAt = Date()
            let snapshot = state
            stateLock.unlock()

            stateStore.save(snapshot)
            onStateChange?(snapshot)
            return count
        }

        private func updateState(_ update: (inout RealtimeBroadcastState) -> Void) {
            stateLock.lock()
            update(&state)
            state.lastUpdatedAt = Date()
            let snapshot = state
            stateLock.unlock()

            stateStore.save(snapshot)
            onStateChange?(snapshot)
        }

        private func saveCurrentState() {
            stateLock.lock()
            let snapshot = state
            stateLock.unlock()

            stateStore.save(snapshot)
            onStateChange?(snapshot)
        }

        private static func describe(_ error: Error) -> String {
            RealtimeSessionStore.realtimeErrorDescription(for: error)
        }

        private static func log(_ message: String) {
            RealtimeLog.log("broadcast", message)
        }

        private static func preview(_ text: String) -> String {
            RealtimeLog.text(text)
        }

        private static func stateSummary(_ state: RealtimeBroadcastState) -> String {
            """
            phase=\(state.phase.rawValue) sourceLen=\(state.sourceText.count) \
            stableLen=\(state.translationSourceText.count) pendingLen=\(state.pendingSourceText.count) \
            translatedLen=\(state.translatedText.count) pendingTranslationLen=\(state.pendingTranslatedText.count) \
            pairs=\(state.sentencePairs.count)
            """
        }

        private static func continuitySummary(
            previousStableLength: Int,
            previousDisplayedTranslationLength: Int,
            previousPairCount: Int,
            state: RealtimeBroadcastState
        ) -> String? {
            let stableRegressed = state.translationSourceText.count < previousStableLength
            let displayedTranslationLength = state.translatedText.count + state.pendingTranslatedText.count
            let translationRegressed = displayedTranslationLength < previousDisplayedTranslationLength
            guard stableRegressed || translationRegressed else { return nil }

            return """
            recognition revised stable transcript stableLen=\(previousStableLength)->\(state.translationSourceText.count) \
            pendingLen=\(state.pendingSourceText.count) \
            translationRetained=\(!translationRegressed) \
            displayedTranslationLen=\(previousDisplayedTranslationLength)->\(displayedTranslationLength) \
            pairs=\(previousPairCount)->\(state.sentencePairs.count)
            """
        }
    }

    extension RealtimeLocalSpeechTranslationPipeline: RealtimeLiveSpeechTranscriberDelegate {
        func realtimeLiveSpeechTranscriber(
            _: RealtimeLiveSpeechTranscriber,
            sessionID: UUID,
            didRecognize result: RealtimeRecognitionResult
        ) {
            guard stateLock.withLock({
                isStarted && sessionID == activeRecognitionSessionID
            }) else {
                return
            }
            handleRecognized(result)
        }

        func realtimeLiveSpeechTranscriber(
            _: RealtimeLiveSpeechTranscriber,
            sessionID: UUID,
            didFail error: Error
        ) {
            guard stateLock.withLock({
                isStarted && sessionID == activeRecognitionSessionID
            }) else {
                return
            }
            fail(error)
        }
    }

    private extension NSLock {
        func withLock<T>(_ body: () -> T) -> T {
            lock()
            defer { unlock() }
            return body()
        }
    }
#endif
