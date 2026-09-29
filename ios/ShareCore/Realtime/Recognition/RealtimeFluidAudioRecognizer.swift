#if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
    import AVFoundation
    import CoreMedia
    import FluidAudio
    import Foundation

    protocol RealtimeFluidAudioRecognizerDelegate: AnyObject {
        func realtimeFluidAudioRecognizer(
            _ recognizer: RealtimeFluidAudioRecognizer,
            sessionID: UUID,
            didRecognize result: RealtimeRecognitionResult
        )
        func realtimeFluidAudioRecognizer(
            _ recognizer: RealtimeFluidAudioRecognizer,
            sessionID: UUID,
            didFail error: Error
        )
    }

    struct RealtimeFluidAudioDiagnostics: Equatable, Sendable {
        let inputAudioOffset: TimeInterval
        let processedAudioOffset: TimeInterval
        let pendingChunkCount: Int
    }

    enum RealtimeFluidAudioLanguageMapper {
        static func nemotronLanguageCode(_ identifier: String) -> String {
            switch identifier.lowercased() {
            case "zh-hans":
                return "zh-CN"
            case "zh-hant":
                return "zh-TW"
            default:
                return identifier
            }
        }
    }

    private enum RealtimeFluidAudioStreamingEngine: Sendable {
        case standard(any StreamingAsrManager)
        case multilingual(StreamingNemotronMultilingualAsrManager)

        func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
            switch self {
            case let .standard(manager):
                await manager.setPartialTranscriptCallback(callback)
            case let .multilingual(manager):
                await manager.setPartialCallback(callback)
            }
        }

        func process(_ buffer: AVAudioPCMBuffer) async throws {
            switch self {
            case let .standard(manager):
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
            case let .multilingual(manager):
                _ = try await manager.process(audioBuffer: buffer)
            }
        }

        func finish() async throws -> String {
            switch self {
            case let .standard(manager):
                return try await manager.finish()
            case let .multilingual(manager):
                return try await manager.finish()
            }
        }

        func reset() async throws {
            switch self {
            case let .standard(manager):
                try await manager.reset()
            case let .multilingual(manager):
                await manager.reset()
            }
        }
    }

    struct RealtimeStreamingTranscriptState {
        private static let minimumBoundaryWordCount = 20
        private static let weakBoundaryWordCount = 32
        private static let maximumBoundaryWordCount = 36
        private static let likelySentenceStarters: Set<String> = [
            "i", "we", "he", "she", "they", "it", "there", "this",
            "what", "why", "how", "when", "but", "so", "then", "meanwhile", "anyway",
        ]
        private static let weakSentenceStarters: Set<String> = [
            "and", "because", "however", "therefore",
        ]
        private static let precedingConnectors: Set<String> = [
            "and", "or", "that", "because", "when", "if", "while", "as", "although", "though",
            "which", "who", "where",
        ]

        private(set) var stableSegments: [RealtimeRecognitionSegment] = []
        private(set) var pendingSegment: RealtimeRecognitionSegment?
        private var currentSegmentStartOffset: TimeInterval = 0
        private var committedModelWordCount = 0
        private var lastPartialText = ""

        var stableText: String {
            stableSegments.map(\.text).joined(separator: "\n\n")
        }

        var pendingText: String {
            pendingSegment?.text ?? ""
        }

        @discardableResult
        mutating func updatePartial(_ text: String, audioOffset: TimeInterval) -> Bool {
            let normalized = Self.normalized(text)
            guard !normalized.isEmpty, normalized != lastPartialText else { return false }
            lastPartialText = normalized

            let modelWords = normalized.split(whereSeparator: \.isWhitespace)
            if modelWords.count <= committedModelWordCount {
                // Word-count based trimming hides everything when the model rewrites or shortens
                // its hypothesis, and for unspaced scripts (CJK) where one "word" is a whole clause.
                RealtimeLog.warn(
                    "fluid",
                    """
                    partial hidden modelWords=\(modelWords.count) committedWords=\(committedModelWordCount) \
                    raw=\(RealtimeLog.text(normalized, limit: 64)) stableTail=\(RealtimeLog.text(stableSegments.last?.text ?? ""))
                    """
                )
            }
            let uncommittedText = modelWords
                .dropFirst(min(committedModelWordCount, modelWords.count))
                .joined(separator: " ")
            let split = RealtimeTranscriptSegmenter.completedSegmentsAndPending(from: uncommittedText)
            let previousPendingID = pendingSegment?.id
            let previousPendingText = pendingSegment?.text ?? ""
            var completedSegments = split.segments.map {
                ($0, RealtimeRecognitionBoundaryReason.punctuation)
            }
            var pendingWords = split.pending.split(whereSeparator: \.isWhitespace)
            while let boundaryIndex = Self.fallbackBoundaryIndex(in: pendingWords) {
                completedSegments.append((
                    pendingWords.prefix(boundaryIndex).joined(separator: " "),
                    .lengthFallback
                ))
                pendingWords.removeFirst(boundaryIndex)
            }
            let pendingText = pendingWords.joined(separator: " ")
            let segmentDuration = completedSegments.isEmpty
                ? 0
                : max(0, audioOffset - currentSegmentStartOffset) / Double(completedSegments.count)

            for (index, completedSegment) in completedSegments.enumerated() {
                let startOffset = currentSegmentStartOffset + segmentDuration * Double(index)
                let endOffset = currentSegmentStartOffset + segmentDuration * Double(index + 1)
                stableSegments.append(RealtimeRecognitionSegment(
                    id: index == 0 ? previousPendingID ?? UUID() : UUID(),
                    text: completedSegment.0,
                    startOffset: startOffset,
                    endOffset: endOffset,
                    boundaryReason: completedSegment.1
                ))
                committedModelWordCount += completedSegment.0.split(whereSeparator: \.isWhitespace).count
            }
            if !completedSegments.isEmpty {
                currentSegmentStartOffset = audioOffset
                RealtimeLog.log(
                    "fluid",
                    """
                    segment commit +\(completedSegments.count) at=\(String(format: "%.1fs", audioOffset)) \
                    reasons=\(completedSegments.map(\.1.rawValue)) committedWords=\(committedModelWordCount)/\(modelWords.count) \
                    new=\(RealtimeLog.segments(completedSegments.map(\.0), tail: 4)) pending=\(RealtimeLog.text(pendingText))
                    """
                )
            }

            pendingSegment = pendingText.isEmpty ? nil : RealtimeRecognitionSegment(
                id: completedSegments.isEmpty ? previousPendingID ?? UUID() : UUID(),
                text: pendingText,
                startOffset: currentSegmentStartOffset,
                endOffset: audioOffset,
                boundaryReason: .stableWindow
            )
            return !completedSegments.isEmpty || previousPendingText != pendingText
        }

        @discardableResult
        mutating func commit(
            _ text: String? = nil,
            boundaryReason: RealtimeRecognitionBoundaryReason,
            audioOffset: TimeInterval
        ) -> Bool {
            if let text {
                updatePartial(text, audioOffset: audioOffset)
            }
            return commitPending(boundaryReason: boundaryReason, endOffset: audioOffset)
        }

        mutating func reset() {
            stableSegments.removeAll()
            pendingSegment = nil
            currentSegmentStartOffset = 0
            committedModelWordCount = 0
            lastPartialText = ""
        }

        mutating func beginEngineGeneration() {
            committedModelWordCount = 0
            lastPartialText = ""
        }

        private mutating func commitPending(
            boundaryReason: RealtimeRecognitionBoundaryReason,
            endOffset: TimeInterval
        ) -> Bool {
            guard let pendingSegment else { return false }
            RealtimeLog.log(
                "fluid",
                """
                pending commit reason=\(boundaryReason.rawValue) at=\(String(format: "%.1fs", endOffset)) \
                text=\(RealtimeLog.text(pendingSegment.text))
                """
            )
            stableSegments.append(RealtimeRecognitionSegment(
                id: pendingSegment.id,
                text: pendingSegment.text,
                startOffset: pendingSegment.startOffset,
                endOffset: endOffset,
                boundaryReason: boundaryReason
            ))
            self.pendingSegment = nil
            currentSegmentStartOffset = endOffset
            return true
        }

        private static func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        private static func fallbackBoundaryIndex(in words: [Substring]) -> Int? {
            guard words.count > minimumBoundaryWordCount else { return nil }

            let strongRange = minimumBoundaryWordCount ..< min(words.count, weakBoundaryWordCount)
            if let index = strongRange.first(where: { isLikelySentenceStart(words, at: $0) }) {
                return index
            }

            if words.count > weakBoundaryWordCount {
                let weakRange = minimumBoundaryWordCount ..< min(words.count, maximumBoundaryWordCount)
                if let index = weakRange.first(where: {
                    weakSentenceStarters.contains(words[$0].lowercased())
                }) {
                    return index
                }
            }

            return words.count >= maximumBoundaryWordCount ? maximumBoundaryWordCount : nil
        }

        private static func isLikelySentenceStart(_ words: [Substring], at index: Int) -> Bool {
            let word = words[index].lowercased()
            guard likelySentenceStarters.contains(word) else { return false }
            let previousWord = words[index - 1].lowercased()
            return !precedingConnectors.contains(previousWord)
        }
    }

    final class RealtimeFluidAudioRecognizer: @unchecked Sendable, RealtimeRecognizer {
        private struct StopResources {
            let processingTask: Task<Void, Never>?
            let streamingEngine: RealtimeFluidAudioStreamingEngine?
            let sessionID: UUID
        }

        private struct PendingAudioWork {
            let samples: [Float]
            let streamingEngine: RealtimeFluidAudioStreamingEngine
            let endOffset: TimeInterval
        }

        private static let maximumPendingAudioDuration: TimeInterval = 15
        private static let lagReportInterval: TimeInterval = 3

        nonisolated static func acceptsPendingAudio(
            pendingSampleCount: Int,
            incomingSampleCount: Int,
            sampleRate: Int
        ) -> Bool {
            pendingSampleCount + incomingSampleCount <=
                Int(maximumPendingAudioDuration * Double(sampleRate))
        }

        weak var delegate: RealtimeFluidAudioRecognizerDelegate?

        var sampleRate: Int { 16000 }

        private let stateLock = NSLock()
        private let conversionLock = NSLock()
        private let converter = RealtimePCMBufferConverter(commonFormat: .pcmFormatFloat32)!

        private var model: RecognitionFluidAudioModel?
        private var streamingEngine: RealtimeFluidAudioStreamingEngine?
        private var pendingSampleChunks: [[Float]] = []
        private var processingTask: Task<Void, Never>?
        private var transcriptState = RealtimeStreamingTranscriptState()
        private var totalSampleCount = 0
        private var processedSampleCount = 0
        private var callbackAudioOffset: TimeInterval = 0
        private var maximumInputRMS: Float = 0
        private var maximumInputAmplitude: Float = 0
        private var partialCallbackCount = 0
        private var lastReportedLagBucket = 0
        private var engineNeedsReset = false
        private var isPaused = false
        private var isStopping = false
        private var hasReportedRuntimeFailure = false
        private var activeSessionID = UUID()

        init(delegate: RealtimeFluidAudioRecognizerDelegate?) {
            self.delegate = delegate
        }

        var diagnostics: RealtimeFluidAudioDiagnostics {
            stateLock.withLock {
                RealtimeFluidAudioDiagnostics(
                    inputAudioOffset: Double(totalSampleCount) / Double(sampleRate),
                    processedAudioOffset: Double(processedSampleCount) / Double(sampleRate),
                    pendingChunkCount: pendingSampleChunks.count
                )
            }
        }

        func start(model: RecognitionModelDescriptor, locale: Locale, sessionID: UUID) async throws {
            await stop()
            prepareForStart(sessionID: sessionID)

            guard case let .fluidAudio(fluidAudioModel) = model.download,
                  model.runtime == .fluidAudio
            else {
                throw RealtimeRecognizerError.unsupportedModel(model.id)
            }

            let modelDirectory = await RecognitionModelStore.shared.cachedModelURL(for: model)
            let loadStartedAt = Date()
            let engine: RealtimeFluidAudioStreamingEngine
            switch fluidAudioModel {
            case .parakeetEOU320, .parakeetEOU1280:
                let manager = StreamingEouAsrManager(
                    chunkSize: fluidAudioModel == .parakeetEOU320 ? .ms320 : .ms1280
                )
                try await manager.loadModels(to: modelDirectory)
                await manager.setEouCallback { [weak self] text in
                    self?.commitEOU(text, sessionID: sessionID)
                }
                engine = .standard(manager)
            case .nemotronStreaming560, .nemotronStreaming1120, .nemotronStreaming2240:
                let chunkSize: NemotronChunkSize = switch fluidAudioModel {
                case .nemotronStreaming560: .ms560
                case .nemotronStreaming1120: .ms1120
                default: .ms2240
                }
                let manager = StreamingNemotronAsrManager(
                    requestedChunkSize: chunkSize
                )
                let repo = chunkSize.repo
                try await manager.loadModels(
                    from: modelDirectory.appendingPathComponent(repo.folderName, isDirectory: true)
                )
                engine = .standard(manager)
            case .nemotronMultilingual2240:
                let variantDirectory = modelDirectory
                    .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
                    .appendingPathComponent("multilingual/2240ms", isDirectory: true)
                let manager = StreamingNemotronMultilingualAsrManager()
                try await manager.loadModels(from: variantDirectory)
                let languageCode = locale.identifier == "und"
                    ? "auto"
                    : RealtimeFluidAudioLanguageMapper.nemotronLanguageCode(locale.identifier)
                await manager.setLanguage(languageCode)
                engine = .multilingual(manager)
            }
            await engine.setPartialTranscriptCallback { [weak self] text in
                self?.publishStreamingPartial(text, sessionID: sessionID)
            }
            stateLock.withLock {
                self.model = fluidAudioModel
                streamingEngine = engine
            }
            RealtimeLog.log(
                "fluid",
                """
                model loaded model=\(fluidAudioModel.rawValue) locale=\(locale.identifier) \
                loadMs=\(Int(Date().timeIntervalSince(loadStartedAt) * 1000))
                """
            )
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            conversionLock.lock()
            let pcmBuffer = converter.pcmBuffer(from: sampleBuffer)
            conversionLock.unlock()
            guard let pcmBuffer, let samples = rawFloatSamples(from: pcmBuffer) else { return }
            append(samples)
        }

        func append(_ pcmBuffer: AVAudioPCMBuffer) {
            guard let samples = floatSamples(from: pcmBuffer) else { return }
            append(samples)
        }

        func append(_ audioSamples: [Float]) {
            guard !audioSamples.isEmpty else { return }
            var squareSum = 0.0
            var peak: Float = 0
            for sample in audioSamples {
                squareSum += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
            }
            let rms = Float(sqrt(squareSum / Double(audioSamples.count)))
            stateLock.lock()
            guard !isPaused, !isStopping, streamingEngine != nil else {
                stateLock.unlock()
                return
            }
            let pendingSampleCount = totalSampleCount - processedSampleCount
            guard Self.acceptsPendingAudio(
                pendingSampleCount: pendingSampleCount,
                incomingSampleCount: audioSamples.count,
                sampleRate: sampleRate
            )
            else {
                isPaused = true
                let sessionID = activeSessionID
                stateLock.unlock()
                RealtimeLog.warn(
                    "fluid",
                    "audio backlog exceeded pendingSeconds=\(Double(pendingSampleCount) / Double(sampleRate)) recognizer paused"
                )
                reportRuntimeFailure(RealtimeRecognizerError.audioBacklogExceeded, sessionID: sessionID)
                return
            }
            pendingSampleChunks.append(audioSamples)
            totalSampleCount += audioSamples.count
            let lagSeconds = Double(totalSampleCount - processedSampleCount) / Double(sampleRate)
            let lagBucket = Int(lagSeconds / Self.lagReportInterval)
            if lagBucket > lastReportedLagBucket || (lagBucket == 0 && lastReportedLagBucket > 0) {
                lastReportedLagBucket = lagBucket
                // Recognition falling behind delays captions and can end in a backlog failure.
                RealtimeLog.warn("fluid", "processing lag \(String(format: "%.1f", lagSeconds))s chunks=\(pendingSampleChunks.count)")
            }
            maximumInputRMS = max(maximumInputRMS, rms)
            maximumInputAmplitude = max(maximumInputAmplitude, peak)
            if processingTask == nil {
                let sessionID = activeSessionID
                processingTask = Task { [weak self] in
                    await self?.processPendingAudio(sessionID: sessionID)
                }
            }
            stateLock.unlock()
        }

        func setPaused(_ isPaused: Bool) {
            stateLock.withLock {
                self.isPaused = isPaused
            }
        }

        func stop() async {
            let resources = stateLock.withLock {
                isPaused = true
                return StopResources(
                    processingTask: processingTask,
                    streamingEngine: streamingEngine,
                    sessionID: activeSessionID
                )
            }

            await resources.processingTask?.value

            var finalTextLength = 0
            do {
                if let engine = resources.streamingEngine {
                    let finalText = try await engine.finish()
                    finalTextLength = finalText.count
                    let endOffset = stateLock.withLock {
                        Double(processedSampleCount) / Double(sampleRate)
                    }
                    _ = stateLock.withLock {
                        transcriptState.commit(
                            finalText,
                            boundaryReason: .terminal,
                            audioOffset: endOffset
                        )
                    }
                    publishCurrentSnapshot(isTerminal: true, sessionID: resources.sessionID)
                    try await engine.reset()
                }
            } catch {
                reportRuntimeFailure(error, sessionID: resources.sessionID)
            }

            let finalDiagnostics = diagnostics
            let signal = stateLock.withLock {
                (model?.rawValue ?? "none", maximumInputRMS, maximumInputAmplitude, partialCallbackCount)
            }
            if finalDiagnostics.inputAudioOffset > 0 {
                RealtimeLog.log(
                    "fluid",
                    """
                    stopped model=\(signal.0) inputSeconds=\(finalDiagnostics.inputAudioOffset) \
                    processedSeconds=\(finalDiagnostics.processedAudioOffset) \
                    maxRMS=\(signal.1) peak=\(signal.2) partialCallbacks=\(signal.3) \
                    finalChars=\(finalTextLength) pendingChunks=\(finalDiagnostics.pendingChunkCount)
                    """
                )
            }
            stateLock.withLock {
                isStopping = true
                isPaused = false
                model = nil
                streamingEngine = nil
                pendingSampleChunks.removeAll()
                processingTask = nil
                transcriptState.reset()
                totalSampleCount = 0
                processedSampleCount = 0
                callbackAudioOffset = 0
                maximumInputRMS = 0
                maximumInputAmplitude = 0
                partialCallbackCount = 0
                lastReportedLagBucket = 0
                engineNeedsReset = false
                activeSessionID = UUID()
            }
        }
    }

    private extension RealtimeFluidAudioRecognizer {
        func prepareForStart(sessionID: UUID) {
            stateLock.withLock {
                isStopping = false
                isPaused = false
                hasReportedRuntimeFailure = false
                pendingSampleChunks.removeAll()
                processingTask = nil
                transcriptState.reset()
                totalSampleCount = 0
                processedSampleCount = 0
                callbackAudioOffset = 0
                maximumInputRMS = 0
                maximumInputAmplitude = 0
                partialCallbackCount = 0
                lastReportedLagBucket = 0
                engineNeedsReset = false
                activeSessionID = sessionID
            }
        }

        func processPendingAudio(sessionID: UUID) async {
            defer {
                stateLock.withLock {
                    if sessionID == activeSessionID {
                        processingTask = nil
                    }
                }
            }
            while !Task.isCancelled {
                let work = stateLock.withLock { () -> PendingAudioWork? in
                    guard sessionID == activeSessionID,
                          !pendingSampleChunks.isEmpty,
                          let streamingEngine
                    else {
                        return nil
                    }
                    let samples = pendingSampleChunks.removeFirst()
                    let endOffset = Double(processedSampleCount + samples.count) / Double(sampleRate)
                    callbackAudioOffset = endOffset
                    return PendingAudioWork(
                        samples: samples,
                        streamingEngine: streamingEngine,
                        endOffset: endOffset
                    )
                }
                guard let work else { return }
                guard let buffer = Self.pcmBuffer(from: work.samples) else {
                    reportRuntimeFailure(
                        RealtimeRecognizerError.audioBufferAllocationFailed,
                        sessionID: sessionID
                    )
                    return
                }

                do {
                    try await work.streamingEngine.process(buffer)

                    let shouldReset = stateLock.withLock { () -> Bool in
                        processedSampleCount += work.samples.count
                        return engineNeedsReset
                    }
                    if shouldReset {
                        RealtimeLog.log("fluid", "engine reset after EOU at=\(String(format: "%.1fs", work.endOffset))")
                        publishCurrentSnapshot(sessionID: sessionID)
                        try await work.streamingEngine.reset()
                        stateLock.withLock {
                            engineNeedsReset = false
                            transcriptState.beginEngineGeneration()
                        }
                    }
                } catch {
                    reportRuntimeFailure(error, sessionID: sessionID)
                    return
                }
            }
        }

        func publishStreamingPartial(_ text: String, sessionID: UUID) {
            let changed = stateLock.withLock {
                partialCallbackCount += 1
                return transcriptState.updatePartial(text, audioOffset: callbackAudioOffset)
            }
            if changed {
                publishCurrentSnapshot(sessionID: sessionID)
            }
        }

        func commitEOU(_ text: String, sessionID: UUID) {
            RealtimeLog.log("fluid", "eou text=\(RealtimeLog.text(text))")
            let changed = stateLock.withLock { () -> Bool in
                let committed = transcriptState.commit(
                    text,
                    boundaryReason: .modelEOU,
                    audioOffset: callbackAudioOffset
                )
                engineNeedsReset = true
                return committed
            }
            if changed {
                publishCurrentSnapshot(sessionID: sessionID)
            }
        }

        func publishCurrentSnapshot(
            isTerminal: Bool = false,
            sessionID: UUID
        ) {
            let state = stateLock.withLock {
                (
                    !isStopping && sessionID == activeSessionID,
                    transcriptState.stableSegments,
                    transcriptState.pendingSegment,
                    Double(processedSampleCount) / Double(sampleRate)
                )
            }
            guard state.0 else { return }
            let snapshot = RealtimeRecognitionSnapshot(
                stableSegments: state.1,
                pendingSegment: state.2,
                audioOffset: state.3,
                isTerminal: isTerminal
            )
            guard !snapshot.visibleText.isEmpty else { return }
            delegate?.realtimeFluidAudioRecognizer(
                self,
                sessionID: sessionID,
                didRecognize: RealtimeRecognitionResult(snapshot: snapshot)
            )
        }

        func reportRuntimeFailure(_ error: Error, sessionID: UUID) {
            guard !RealtimeSessionStore.isCancellationError(error) else { return }
            let shouldReport = stateLock.withLock { () -> Bool in
                let shouldReport = !isStopping &&
                    sessionID == activeSessionID &&
                    !hasReportedRuntimeFailure
                if shouldReport {
                    hasReportedRuntimeFailure = true
                }
                return shouldReport
            }
            guard shouldReport else { return }
            RealtimeLog.warn("fluid", "runtime failure error=\(String(describing: error))")
            delegate?.realtimeFluidAudioRecognizer(self, sessionID: sessionID, didFail: error)
        }

        func floatSamples(from pcmBuffer: AVAudioPCMBuffer) -> [Float]? {
            let format = pcmBuffer.format
            if format.sampleRate == 16000,
               format.channelCount == 1,
               format.commonFormat == .pcmFormatInt16,
               !format.isInterleaved,
               let channel = pcmBuffer.int16ChannelData?.pointee
            {
                return (0 ..< Int(pcmBuffer.frameLength)).map { Float(channel[$0]) / 32768 }
            }
            conversionLock.lock()
            let convertedBuffer = converter.pcmBuffer(from: pcmBuffer)
            conversionLock.unlock()
            guard let convertedBuffer else { return nil }
            return rawFloatSamples(from: convertedBuffer)
        }

        func rawFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )!
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress else { return }
                buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
            }
            return buffer
        }
    }
#endif
