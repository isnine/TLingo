#if os(macOS) || os(iOS)
    import AVFoundation
    import CoreMedia
    import Speech

    protocol RealtimeLiveSpeechTranscriberDelegate: AnyObject {
        func realtimeLiveSpeechTranscriber(
            _ transcriber: RealtimeLiveSpeechTranscriber,
            sessionID: UUID,
            didRecognize result: RealtimeRecognitionResult
        )
        func realtimeLiveSpeechTranscriber(
            _ transcriber: RealtimeLiveSpeechTranscriber,
            sessionID: UUID,
            didFail error: Error
        )
    }

    final class RealtimeLiveSpeechTranscriber: @unchecked Sendable {
        weak var delegate: RealtimeLiveSpeechTranscriberDelegate?

        private static let reusablePCMBufferCount = 48
        private static let analyzerInputBufferLimit = 32

        private let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        private var analyzer: SpeechAnalyzer?
        private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        private var analyzeTask: Task<Void, Never>?
        private var resultTask: Task<Void, Never>?
        private var legacyRecognizer: RealtimeLegacySpeechRecognizer?
        private var reservedLocale: Locale?
        private let stateLock = NSLock()
        private let conversionLock = NSLock()
        private var isPaused = false
        private var isStopping = false
        private var isDraining = false
        private var hasReportedRuntimeFailure = false
        private var activeSessionID = UUID()
        private var transcriptAccumulator = RealtimeTranscriptAccumulator()
        /// Audio handed to the recognizer since start; it matches the history recording, which
        /// receives the same buffers, so result time ranges line up with playback.
        private var receivedAudioFrames: AVAudioFramePosition = 0
        private var finalTokenTimings: [RealtimeRecognitionTokenTiming] = []
        private var volatileTokenTimings: [RealtimeRecognitionTokenTiming] = []
        private var reusablePCMBuffers = [AVAudioPCMBuffer?](
            repeating: nil,
            count: reusablePCMBufferCount
        )
        private var reusablePCMBufferCursor = 0

        func start(locale: Locale, sessionID: UUID) async throws {
            let authorized = await requestAuthorization()
            guard authorized else { throw RealtimeCaptureError.speechNotAuthorized }

            await stop()
            prepareForStart(sessionID: sessionID)

            do {
                try await startSpeechTranscriber(locale: locale, sessionID: sessionID)
                RealtimeLog.log("asr", "started engine=SpeechTranscriber locale=\(locale.identifier)")
            } catch {
                RealtimeLog.warn(
                    "asr",
                    "SpeechTranscriber unavailable locale=\(locale.identifier) error=\(String(describing: error)) fallback=Dictation"
                )
                await stop()
                prepareForStart(sessionID: sessionID)
                do {
                    try await startDictationTranscriber(locale: locale, sessionID: sessionID)
                    RealtimeLog.log("asr", "started engine=DictationTranscriber locale=\(locale.identifier)")
                } catch {
                    RealtimeLog.warn(
                        "asr",
                        "DictationTranscriber unavailable locale=\(locale.identifier) error=\(String(describing: error)) fallback=SFSpeech"
                    )
                    await stop()
                    prepareForStart(sessionID: sessionID)
                    legacyRecognizer = try RealtimeLegacySpeechRecognizer(
                        locale: locale,
                        didRecognize: { [weak self] result in
                            self?.publishRecognitionResult(result, sessionID: sessionID)
                        },
                        didFail: { [weak self] error in
                            guard let self else { return }
                            self.reportRuntimeFailure(error, sessionID: sessionID)
                        }
                    )
                }
            }
        }

        private func startSpeechTranscriber(locale: Locale, sessionID: UUID) async throws {
            guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw RealtimeCaptureError.speechRecognizerUnavailable
            }

            let transcriber = SpeechTranscriber(
                locale: supportedLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange]
            )
            try await installAssets(for: [transcriber], locale: supportedLocale)
            reservedLocale = supportedLocale

            let inputStream = makeInputStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await startAnalyzer(analyzer, inputStream: inputStream, sessionID: sessionID)

            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handleResultText(result.text, isFinal: result.isFinal, sessionID: sessionID)
                    }
                    self?.reportUnexpectedSpeechEnd(sessionID: sessionID)
                } catch {
                    guard let self else { return }
                    self.reportRuntimeFailure(error, sessionID: sessionID)
                }
            }
        }

        private func startDictationTranscriber(locale: Locale, sessionID: UUID) async throws {
            guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                throw RealtimeCaptureError.speechRecognizerUnavailable
            }

            let transcriber = DictationTranscriber(
                locale: supportedLocale,
                contentHints: [],
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange]
            )
            try await installAssets(for: [transcriber], locale: supportedLocale)
            reservedLocale = supportedLocale

            let inputStream = makeInputStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await startAnalyzer(analyzer, inputStream: inputStream, sessionID: sessionID)

            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handleResultText(result.text, isFinal: result.isFinal, sessionID: sessionID)
                    }
                    self?.reportUnexpectedSpeechEnd(sessionID: sessionID)
                } catch {
                    guard let self else { return }
                    self.reportRuntimeFailure(error, sessionID: sessionID)
                }
            }
        }

        private func installAssets(for modules: [any SpeechModule], locale: Locale) async throws {
            let status = await AssetInventory.status(forModules: modules)
            guard status != .unsupported else {
                throw RealtimeCaptureError.speechRecognizerUnavailable
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                RealtimeLog.log("asr", "installing speech assets locale=\(locale.identifier)")
                try await request.downloadAndInstall()
            }
            try await AssetInventory.reserve(locale: locale)
        }

        private func makeInputStream() -> AsyncStream<AnalyzerInput> {
            AsyncStream<AnalyzerInput>(
                bufferingPolicy: .bufferingNewest(Self.analyzerInputBufferLimit)
            ) { continuation in
                self.inputContinuation = continuation
            }
        }

        private func startAnalyzer(
            _ analyzer: SpeechAnalyzer,
            inputStream: AsyncStream<AnalyzerInput>,
            sessionID: UUID
        ) async throws {
            try await analyzer.prepareToAnalyze(in: audioFormat)
            self.analyzer = analyzer
            analyzeTask = Task { [weak self] in
                do {
                    try await analyzer.start(inputSequence: inputStream)
                } catch {
                    guard let self else { return }
                    self.reportRuntimeFailure(error, sessionID: sessionID)
                }
            }
        }

        private func handleResultText(_ text: AttributedString, isFinal: Bool, sessionID: UUID) {
            let recognizedText = String(text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recognizedText.isEmpty else { return }
            if isFinal {
                RealtimeLog.log("asr", "final text=\(RealtimeLog.text(recognizedText, limit: 64))")
            }
            publishRecognitionResult(
                RealtimeRecognitionResult(
                    text: recognizedText,
                    confidence: Self.averageConfidence(in: text),
                    state: isFinal ? .final : .partial
                ),
                tokenTimings: Self.tokenTimings(in: text),
                sessionID: sessionID
            )
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            stateLock.lock()
            let isPaused = isPaused
            stateLock.unlock()

            guard !isPaused else { return }

            conversionLock.lock()
            let pcmBuffer = pcmBuffer(from: sampleBuffer)
            conversionLock.unlock()

            guard let pcmBuffer else { return }
            let startTime = reserveAudioTime(for: pcmBuffer)
            if legacyRecognizer?.append(pcmBuffer) == true {
                return
            }
            guard let inputContinuation else { return }
            inputContinuation.yield(AnalyzerInput(buffer: pcmBuffer, bufferStartTime: startTime))
        }

        func append(_ pcmBuffer: AVAudioPCMBuffer) {
            stateLock.lock()
            let isPaused = isPaused
            stateLock.unlock()

            guard !isPaused else { return }
            let startTime = reserveAudioTime(for: pcmBuffer)
            if legacyRecognizer?.append(pcmBuffer) == true {
                return
            }
            guard let inputContinuation else { return }
            inputContinuation.yield(AnalyzerInput(buffer: pcmBuffer, bufferStartTime: startTime))
        }

        /// Explicit start times keep the analyzer timeline aligned even when the bounded input
        /// stream drops buffers under load. They must be exact sample counts: `CMTime(seconds:)`
        /// marks the time as rounded, and SpeechAnalyzer then rejects contiguous buffers as
        /// overlapping (SFSpeechErrorDomain "timestamp overlaps or precedes prior audio input").
        private func reserveAudioTime(for pcmBuffer: AVAudioPCMBuffer) -> CMTime {
            withStateLock {
                let startFrame = receivedAudioFrames
                receivedAudioFrames += AVAudioFramePosition(pcmBuffer.frameLength)
                return CMTime(value: startFrame, timescale: CMTimeScale(pcmBuffer.format.sampleRate))
            }
        }

        func setPaused(_ isPaused: Bool) {
            stateLock.lock()
            self.isPaused = isPaused
            stateLock.unlock()
        }

        func stop() async {
            let resources = withStateLock {
                isPaused = true
                isDraining = true
                let resources = (
                    inputContinuation,
                    analyzeTask,
                    resultTask,
                    analyzer,
                    reservedLocale,
                    legacyRecognizer,
                    activeSessionID
                )
                inputContinuation = nil
                analyzeTask = nil
                resultTask = nil
                self.analyzer = nil
                self.reservedLocale = nil
                self.legacyRecognizer = nil
                return resources
            }
            resources.0?.finish()
            resetReusablePCMBuffers()
            resources.5?.stop()

            if let analyzer = resources.3 {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    await analyzer.cancelAndFinishNow()
                }
            }
            await resources.1?.value
            await resources.2?.value
            if let reservedLocale = resources.4 {
                await AssetInventory.release(reservedLocale: reservedLocale)
            }
            publishTerminalSnapshotIfNeeded(sessionID: resources.6)
            withStateLock {
                isStopping = true
                isDraining = false
                isPaused = false
                activeSessionID = UUID()
            }
        }

        private func prepareForStart(sessionID: UUID) {
            stateLock.lock()
            isStopping = false
            isDraining = false
            isPaused = false
            hasReportedRuntimeFailure = false
            activeSessionID = sessionID
            transcriptAccumulator.reset()
            receivedAudioFrames = 0
            finalTokenTimings.removeAll()
            volatileTokenTimings.removeAll()
            stateLock.unlock()
        }

        private func publishRecognitionResult(
            _ result: RealtimeRecognitionResult,
            tokenTimings: [RealtimeRecognitionTokenTiming]? = nil,
            sessionID: UUID
        ) {
            let snapshot = stateLock.withLock { () -> RealtimeRecognitionSnapshot? in
                guard Self.shouldAcceptCallback(
                    sessionID: sessionID,
                    activeSessionID: activeSessionID,
                    isStopping: isStopping
                ) else {
                    return nil
                }
                _ = transcriptAccumulator.append(result, afterLongSilence: false)
                if let tokenTimings {
                    if result.state == .final {
                        finalTokenTimings.append(contentsOf: tokenTimings)
                        volatileTokenTimings.removeAll()
                    } else {
                        volatileTokenTimings = tokenTimings
                    }
                }
                return RealtimeRecognitionSnapshot(
                    stableText: transcriptAccumulator.committedText,
                    volatileText: transcriptAccumulator.partialText,
                    tokenTimings: finalTokenTimings + volatileTokenTimings,
                    isTerminal: false
                )
            }
            guard let snapshot else { return }
            delegate?.realtimeLiveSpeechTranscriber(
                self,
                sessionID: sessionID,
                didRecognize: RealtimeRecognitionResult(
                    snapshot: snapshot,
                    confidence: result.confidence
                )
            )
        }

        private func publishTerminalSnapshotIfNeeded(sessionID: UUID) {
            let snapshot = stateLock.withLock { () -> RealtimeRecognitionSnapshot? in
                guard sessionID == activeSessionID else { return nil }
                let text = transcriptAccumulator.commitPartial()
                guard !text.isEmpty else { return nil }
                return RealtimeRecognitionSnapshot(
                    stableText: text,
                    volatileText: "",
                    tokenTimings: finalTokenTimings + volatileTokenTimings,
                    isTerminal: true
                )
            }
            guard let snapshot else { return }
            delegate?.realtimeLiveSpeechTranscriber(
                self,
                sessionID: sessionID,
                didRecognize: RealtimeRecognitionResult(snapshot: snapshot)
            )
        }

        private func reportUnexpectedSpeechEnd(sessionID: UUID) {
            reportRuntimeFailure(RealtimeCaptureError.speechRecognitionEndedUnexpectedly, sessionID: sessionID)
        }

        private func reportRuntimeFailure(_ error: Error, sessionID: UUID) {
            guard !RealtimeSessionStore.isCancellationError(error) else { return }

            stateLock.lock()
            let shouldReport = Self.shouldAcceptCallback(
                sessionID: sessionID,
                activeSessionID: activeSessionID,
                isStopping: isStopping
            ) && !isDraining && !hasReportedRuntimeFailure
            if shouldReport {
                hasReportedRuntimeFailure = true
            }
            stateLock.unlock()

            guard shouldReport else { return }
            RealtimeLog.warn("asr", "runtime failure error=\(String(describing: error))")
            delegate?.realtimeLiveSpeechTranscriber(self, sessionID: sessionID, didFail: error)
        }

        nonisolated static func shouldAcceptCallback(
            sessionID: UUID,
            activeSessionID: UUID,
            isStopping: Bool
        ) -> Bool {
            !isStopping && sessionID == activeSessionID
        }

        private func requestAuthorization() async -> Bool {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        }

        private func withStateLock<T>(_ body: () -> T) -> T {
            stateLock.lock()
            defer { stateLock.unlock() }
            return body()
        }

        private static func averageConfidence(in text: AttributedString) -> Double {
            var total = 0.0
            var numberOfConfidences = 0

            for run in text.runs {
                if let confidence = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                    total += confidence
                    numberOfConfidences += 1
                }
            }

            guard numberOfConfidences > 0 else { return 0.5 }
            return total / Double(numberOfConfidences)
        }

        private static func tokenTimings(in text: AttributedString) -> [RealtimeRecognitionTokenTiming] {
            text.runs.compactMap { run in
                guard let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                      timeRange.isValid
                else {
                    return nil
                }
                let token = String(text[run.range].characters)
                guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return RealtimeRecognitionTokenTiming(
                    token: token,
                    startTime: timeRange.start.seconds,
                    endTime: timeRange.end.seconds,
                    confidence: run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] ?? 0.5
                )
            }
        }

        private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0,
                  let pcmBuffer = reusablePCMBuffer(frameCount: frameCount),
                  let destination = pcmBuffer.int16ChannelData?.pointee,
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            else {
                return nil
            }

            var listSize = 0
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &listSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: nil
            )
            guard listSize > 0 else { return nil }

            return withUnsafeTemporaryAllocation(
                byteCount: listSize,
                alignment: MemoryLayout<AudioBufferList>.alignment
            ) { rawList -> AVAudioPCMBuffer? in
                guard let baseAddress = rawList.baseAddress else { return nil }

                let audioBufferList = baseAddress.bindMemory(to: AudioBufferList.self, capacity: 1)
                var blockBuffer: CMBlockBuffer?
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: audioBufferList,
                    bufferListSize: listSize,
                    blockBufferAllocator: kCFAllocatorDefault,
                    blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                    blockBufferOut: &blockBuffer
                )
                guard status == noErr else { return nil }

                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                let sourceIsFloat = streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
                var copiedSamples = 0

                for buffer in buffers {
                    guard let data = buffer.mData else { continue }

                    if sourceIsFloat {
                        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
                        for index in 0 ..< sampleCount where copiedSamples < frameCount {
                            let sample = max(-1, min(1, samples[index]))
                            destination[copiedSamples] = Int16(sample * Float(Int16.max))
                            copiedSamples += 1
                        }
                    } else {
                        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                        let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
                        let remainingSamples = frameCount - copiedSamples
                        let samplesToCopy = min(sampleCount, remainingSamples)
                        guard samplesToCopy > 0 else { break }

                        destination
                            .advanced(by: copiedSamples)
                            .update(from: samples, count: samplesToCopy)
                        copiedSamples += samplesToCopy
                    }
                }

                guard copiedSamples > 0 else { return nil }
                pcmBuffer.frameLength = AVAudioFrameCount(copiedSamples)
                return pcmBuffer
            }
        }

        private func reusablePCMBuffer(frameCount: Int) -> AVAudioPCMBuffer? {
            let frameCapacity = AVAudioFrameCount(frameCount)
            let index = reusablePCMBufferCursor
            reusablePCMBufferCursor = (reusablePCMBufferCursor + 1) % Self.reusablePCMBufferCount

            if let buffer = reusablePCMBuffers[index], buffer.frameCapacity >= frameCapacity {
                buffer.frameLength = 0
                return buffer
            }

            let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: frameCapacity
            )
            reusablePCMBuffers[index] = buffer
            return buffer
        }

        private func resetReusablePCMBuffers() {
            conversionLock.lock()
            reusablePCMBuffers = [AVAudioPCMBuffer?](
                repeating: nil,
                count: Self.reusablePCMBufferCount
            )
            reusablePCMBufferCursor = 0
            conversionLock.unlock()
        }
    }
#endif
