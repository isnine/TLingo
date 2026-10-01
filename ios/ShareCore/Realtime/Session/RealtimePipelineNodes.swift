#if os(macOS)
    import AVFoundation
    import CoreMedia
    import Foundation
    import os

    struct RealtimeAudioChunk: @unchecked Sendable {
        let pcmBuffer: AVAudioPCMBuffer
        let floatSamples: [Float]

        var duration: TimeInterval {
            Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate
        }
    }

    final class RealtimePipelineAudioFanout: @unchecked Sendable {
        private struct BufferedChunk {
            let chunk: RealtimeAudioChunk
            let audioOffset: TimeInterval
        }

        private struct Route {
            let recognitionNodes: [RealtimeRecognitionNode]
            let audioOffset: TimeInterval
        }

        private static let maximumStartupBufferDuration: TimeInterval = 15
        /// Startup replay is appended synchronously, so a node's recognizer input queue must hold
        /// all of it plus live audio arriving while recognition catches up, at 10 ms capture buffers.
        static let startupReplayInputBufferLimit = Int(maximumStartupBufferDuration * 2 / 0.01)

        private let lock = NSLock()
        private let conversionLock = NSLock()
        private let converter = RealtimePCMBufferConverter(
            sampleRate: 16000,
            channels: 1,
            commonFormat: .pcmFormatInt16
        )!
        private var recognitionNodes: [RealtimeRecognitionNode] = []
        private var audioOffset: TimeInterval = 0
        private var isBufferingStartupAudio = false
        private var isPaused = false
        private var startupBuffer: [BufferedChunk] = []

        func update(recognitionNodes: [RealtimeRecognitionNode]) {
            lock.withLock {
                guard !recognitionNodes.isEmpty else {
                    self.recognitionNodes = recognitionNodes
                    return
                }
                isBufferingStartupAudio = false
                if let firstBufferedChunk = startupBuffer.first {
                    let replayBaseOffset = Self.replayBaseOffset(for: firstBufferedChunk)
                    for node in recognitionNodes {
                        node.setTimelineBaseOffset(replayBaseOffset)
                    }
                }
                for bufferedChunk in startupBuffer {
                    for node in recognitionNodes {
                        node.append(bufferedChunk.chunk, audioOffset: bufferedChunk.audioOffset)
                    }
                }
                startupBuffer.removeAll()
                self.recognitionNodes = recognitionNodes
            }
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            guard let chunk = makeChunk(from: sampleBuffer) else { return }
            route(chunk)
        }

        func append(_ pcmBuffer: AVAudioPCMBuffer) {
            guard let chunk = makeChunk(from: pcmBuffer) else { return }
            route(chunk)
        }

        func beginStartupBuffering() {
            lock.withLock {
                audioOffset = 0
                startupBuffer.removeAll()
                isBufferingStartupAudio = true
                isPaused = false
            }
        }

        func setPaused(_ isPaused: Bool) {
            lock.withLock {
                self.isPaused = isPaused
            }
        }

        func resetTimeline() {
            lock.withLock {
                audioOffset = 0
                startupBuffer.removeAll()
                isBufferingStartupAudio = false
                isPaused = false
            }
        }

        var currentAudioOffset: TimeInterval {
            lock.withLock { audioOffset }
        }

        var startupBufferedDuration: TimeInterval {
            lock.withLock {
                guard let first = startupBuffer.first, let last = startupBuffer.last else { return 0 }
                return last.audioOffset - first.audioOffset + first.chunk.duration
            }
        }

        var startupReplayBaseOffset: TimeInterval {
            lock.withLock {
                startupBuffer.first.map(Self.replayBaseOffset(for:)) ?? 0
            }
        }

        private static func replayBaseOffset(for first: BufferedChunk) -> TimeInterval {
            return max(0, first.audioOffset - first.chunk.duration)
        }

        private func route(_ chunk: RealtimeAudioChunk) {
            let route = lock.withLock { () -> Route? in
                guard !isPaused else { return nil }
                audioOffset += chunk.duration
                let offset = audioOffset
                if recognitionNodes.isEmpty, isBufferingStartupAudio {
                    startupBuffer.append(BufferedChunk(chunk: chunk, audioOffset: offset))
                    while let first = startupBuffer.first,
                          offset - first.audioOffset + first.chunk.duration > Self.maximumStartupBufferDuration
                    {
                        startupBuffer.removeFirst()
                    }
                }
                return Route(
                    recognitionNodes: recognitionNodes,
                    audioOffset: offset
                )
            }
            guard let route else { return }
            for node in route.recognitionNodes {
                node.append(chunk, audioOffset: route.audioOffset)
            }
        }

        private func makeChunk(from sampleBuffer: CMSampleBuffer) -> RealtimeAudioChunk? {
            conversionLock.withLock {
                converter.pcmBuffer(from: sampleBuffer).flatMap(Self.makeChunk)
            }
        }

        private func makeChunk(from pcmBuffer: AVAudioPCMBuffer) -> RealtimeAudioChunk? {
            conversionLock.withLock {
                converter.pcmBuffer(from: pcmBuffer).flatMap(Self.makeChunk)
            }
        }

        private static func makeChunk(from convertedBuffer: AVAudioPCMBuffer) -> RealtimeAudioChunk? {
            let frameLength = Int(convertedBuffer.frameLength)
            guard frameLength > 0,
                  let source = convertedBuffer.int16ChannelData?[0],
                  let pcmBuffer = AVAudioPCMBuffer(
                      pcmFormat: convertedBuffer.format,
                      frameCapacity: convertedBuffer.frameLength
                  ),
                  let destination = pcmBuffer.int16ChannelData?[0]
            else {
                return nil
            }
            pcmBuffer.frameLength = convertedBuffer.frameLength
            destination.update(from: source, count: frameLength)
            let floatSamples = UnsafeBufferPointer(start: source, count: frameLength).map {
                Float($0) / Float(Int16.max)
            }
            return RealtimeAudioChunk(
                pcmBuffer: pcmBuffer,
                floatSamples: floatSamples
            )
        }
    }

    final class RealtimeRecognitionNode: NSObject, @unchecked Sendable {
        let model: RecognitionModelDescriptor
        var onResult: ((UUID, RealtimeRecognitionResult) -> Void)?
        var onFailure: ((UUID, Error) -> Void)?

        private let signposter = OSSignposter(
            subsystem: "com.zanderwang.AITranslator",
            category: "RealtimeRecognitionNode"
        )
        private let lock = NSLock()
        private var recognizer: (any RealtimeRecognizer)?
        private var sessionID = UUID()
        private var timelineBaseOffset: TimeInterval = 0
        private var currentAudioOffset: TimeInterval = 0
        private var latestResult: RealtimeRecognitionResult?

        init(model: RecognitionModelDescriptor) {
            self.model = model
        }

        func start(
            locale: Locale,
            sessionID: UUID,
            timelineBaseOffset: TimeInterval
        ) async throws {
            let signpostID = signposter.makeSignpostID()
            let state = signposter.beginInterval("Load Recognition Model", id: signpostID)
            defer { signposter.endInterval("Load Recognition Model", state) }

            let recognizer: any RealtimeRecognizer
            switch model.runtime {
            case .appleSpeech:
                let transcriber = RealtimeLiveSpeechTranscriber(
                    analyzerInputBufferLimit: RealtimePipelineAudioFanout.startupReplayInputBufferLimit
                )
                transcriber.delegate = self
                recognizer = transcriber
            case .fluidAudio:
                #if arch(arm64) && canImport(FluidAudio)
                    recognizer = RealtimeFluidAudioRecognizer(delegate: self)
                #else
                    throw RealtimeRecognizerError.unsupportedModel(model.id)
                #endif
            case .mlxStreaming:
                #if arch(arm64) && canImport(MLXAudioSTT)
                    let r2t2Recognizer = RealtimeR2T2Recognizer()
                    r2t2Recognizer.onResult = { [weak self] sessionID, result in
                        guard let self else { return }
                        onResult?(sessionID, resultWithTimelineOffset(result))
                    }
                    r2t2Recognizer.onFailure = { [weak self] sessionID, error in
                        self?.onFailure?(sessionID, error)
                    }
                    recognizer = r2t2Recognizer
                #else
                    throw RealtimeRecognizerError.unsupportedModel(model.id)
                #endif
            case .coreML, .mossOffline, .onnx:
                throw RealtimeRecognizerError.unsupportedModel(model.id)
            }

            lock.withLock {
                self.sessionID = sessionID
                self.timelineBaseOffset = timelineBaseOffset
                currentAudioOffset = timelineBaseOffset
                latestResult = nil
                self.recognizer = recognizer
            }

            do {
                try await recognizer.start(model: model, locale: locale, sessionID: sessionID)
                realtimePipelineLogger.info("recognition node loaded model=\(self.model.id, privacy: .public)")
            } catch {
                lock.withLock {
                    self.recognizer = nil
                }
                throw error
            }
        }

        func setTimelineBaseOffset(_ offset: TimeInterval) {
            lock.withLock {
                timelineBaseOffset = offset
                currentAudioOffset = offset
            }
        }

        var currentRecognitionSnapshot: RealtimeRecognitionSnapshot? {
            lock.withLock { latestResult?.snapshot }
        }

        func append(_ chunk: RealtimeAudioChunk, audioOffset: TimeInterval) {
            lock.withLock {
                currentAudioOffset = audioOffset
            }
            let recognizer = currentRecognizer()
            #if arch(arm64) && canImport(FluidAudio)
                if let fluidRecognizer = recognizer as? RealtimeFluidAudioRecognizer {
                    fluidRecognizer.append(chunk.floatSamples)
                    return
                }
            #endif
            #if arch(arm64) && canImport(MLXAudioSTT)
                if let r2t2Recognizer = recognizer as? RealtimeR2T2Recognizer {
                    r2t2Recognizer.append(chunk.floatSamples)
                    return
                }
            #endif
            recognizer?.append(chunk.pcmBuffer)
        }

        func setPaused(_ isPaused: Bool) {
            currentRecognizer()?.setPaused(isPaused)
        }

        func stop() async {
            let recognizer = lock.withLock {
                let recognizer = self.recognizer
                self.recognizer = nil
                sessionID = UUID()
                return recognizer
            }
            await recognizer?.stop()
        }

        private func currentRecognizer() -> (any RealtimeRecognizer)? {
            lock.withLock { recognizer }
        }

        private func resultWithTimelineOffset(
            _ result: RealtimeRecognitionResult
        ) -> RealtimeRecognitionResult {
            let timeline = lock.withLock {
                (
                    baseOffset: timelineBaseOffset,
                    audioOffset: result.audioOffset.map { timelineBaseOffset + $0 } ?? currentAudioOffset
                )
            }
            let adjustedResult: RealtimeRecognitionResult
            if let snapshot = result.snapshot {
                let adjustedSegments = snapshot.stableSegments.map { segment in
                    RealtimeRecognitionSegment(
                        id: segment.id,
                        text: segment.text,
                        startOffset: timeline.baseOffset + segment.startOffset,
                        endOffset: timeline.baseOffset + segment.endOffset,
                        speakerID: segment.speakerID,
                        boundaryReason: segment.boundaryReason
                    )
                }
                let adjustedPending = snapshot.pendingSegment.map { segment in
                    RealtimeRecognitionSegment(
                        id: segment.id,
                        text: segment.text,
                        startOffset: timeline.baseOffset + segment.startOffset,
                        endOffset: timeline.baseOffset + segment.endOffset,
                        speakerID: segment.speakerID,
                        boundaryReason: segment.boundaryReason
                    )
                }
                adjustedResult = RealtimeRecognitionResult(
                    snapshot: adjustedSegments.isEmpty && adjustedPending == nil
                        ? RealtimeRecognitionSnapshot(
                            stableText: snapshot.stableText,
                            volatileText: snapshot.volatileText,
                            tokenTimings: snapshot.tokenTimings,
                            audioOffset: timeline.audioOffset,
                            isTerminal: snapshot.isTerminal
                        )
                        : RealtimeRecognitionSnapshot(
                            stableSegments: adjustedSegments,
                            pendingSegment: adjustedPending,
                            tokenTimings: snapshot.tokenTimings,
                            audioOffset: timeline.audioOffset,
                            isTerminal: snapshot.isTerminal
                        ),
                    confidence: result.confidence
                )
            } else {
                adjustedResult = RealtimeRecognitionResult(
                    text: result.text,
                    confidence: result.confidence,
                    state: result.state,
                    audioOffset: timeline.audioOffset
                )
            }
            lock.withLock {
                latestResult = adjustedResult
            }
            return adjustedResult
        }
    }

    extension RealtimeRecognitionNode: RealtimeLiveSpeechTranscriberDelegate {
        nonisolated func realtimeLiveSpeechTranscriber(
            _: RealtimeLiveSpeechTranscriber,
            sessionID: UUID,
            didRecognize result: RealtimeRecognitionResult
        ) {
            onResult?(sessionID, resultWithTimelineOffset(result))
        }

        nonisolated func realtimeLiveSpeechTranscriber(
            _: RealtimeLiveSpeechTranscriber,
            sessionID: UUID,
            didFail error: Error
        ) {
            onFailure?(sessionID, error)
        }
    }

    #if arch(arm64) && canImport(FluidAudio)
        extension RealtimeRecognitionNode: RealtimeFluidAudioRecognizerDelegate {
            nonisolated func realtimeFluidAudioRecognizer(
                _: RealtimeFluidAudioRecognizer,
                sessionID: UUID,
                didRecognize result: RealtimeRecognitionResult
            ) {
                onResult?(sessionID, resultWithTimelineOffset(result))
            }

            nonisolated func realtimeFluidAudioRecognizer(
                _: RealtimeFluidAudioRecognizer,
                sessionID: UUID,
                didFail error: Error
            ) {
                onFailure?(sessionID, error)
            }
        }
    #endif

#endif
