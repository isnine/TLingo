#if os(macOS) || os(iOS)
    import AVFoundation
    import Foundation
    import os
    import Speech
    #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
        import CoreML
        import FluidAudio
    #endif

    public enum RealtimeHistoryAudioPostProcessor {
        private static let audioReadFrameCapacity: AVAudioFrameCount = 4096
        private static let recognitionTimeout: TimeInterval = 18
        private static let translationAttemptLimit = 2
        private static let translationRetryDelay: Duration = .milliseconds(300)
        private static let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "RealtimeHistoryAudio")

        public static func process(
            _ session: RealtimeHistorySession,
            recognitionModelID: String = AppPreferences.shared.realtimeRecognitionModelID
        ) async throws -> RealtimeHistorySession {
            try Task.checkCancellation()
            guard let sourceLanguage = SourceLanguageOption.realtimeOption(englishName: session.sourceLanguage),
                  let targetLanguage = TargetLanguageOption.realtimeOption(englishName: session.targetLanguage)
            else {
                throw RealtimeHistoryAudioPostProcessorError.unsupportedLanguage
            }
            let recognitionModel = await resolvedRecognitionModel(for: recognitionModelID, sourceLanguage: sourceLanguage)
            try Task.checkCancellation()
            let transcriptSegments = try await transcribe(
                session.audioRecordings,
                language: sourceLanguage,
                recognitionModel: recognitionModel
            )
            try Task.checkCancellation()
            let translatedSegments = try await translate(
                transcriptSegments,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )

            var updated = session
            updated.delayedTranscriptSegments = translatedSegments
            updated.delayedConversationItems = RealtimeHistoryConversationBuilder.build(from: updated)
            updated = sessionByReplacingTranscriptionModels(
                in: updated,
                sources: Set(translatedSegments.map(\.source)),
                model: recognitionModel
            )
            return updated
        }

        public static func processMicrophoneRecording(
            _ session: RealtimeHistorySession,
            recognitionModelID: String = AppPreferences.shared.realtimeRecognitionModelID,
            progress: @escaping @MainActor (RealtimeHistorySession) -> Void = { _ in }
        ) async throws -> RealtimeHistorySession {
            try Task.checkCancellation()
            let microphoneRecordings = session.audioRecordings.filter { $0.source == .microphone && $0.hasPlayableAudio }
            guard !microphoneRecordings.isEmpty else {
                throw RealtimeHistoryAudioPostProcessorError.microphoneRecordingUnavailable
            }

            guard let sourceLanguage = SourceLanguageOption.realtimeOption(englishName: session.sourceLanguage),
                  let targetLanguage = TargetLanguageOption.realtimeOption(englishName: session.targetLanguage)
            else {
                throw RealtimeHistoryAudioPostProcessorError.unsupportedLanguage
            }
            let recognitionModel = await resolvedRecognitionModel(for: recognitionModelID, sourceLanguage: sourceLanguage)
            try Task.checkCancellation()
            let session = sessionByReplacingTranscriptionModel(in: session, source: .microphone, model: recognitionModel)
            let progressGate = RealtimeHistoryProgressGate()
            defer { progressGate.invalidate() }
            let transcriptionPhase = progressGate.currentPhase()
            let recognizedSegments = TranscriptSegmentStore()
            let transcriptSegments = try await transcribe(
                microphoneRecordings,
                language: sourceLanguage,
                recognitionModel: recognitionModel
            ) { segment in
                let segments = recognizedSegments.upserting(segment)
                await reportProgress(
                    sessionByReplacingTranscriptSegments(in: session, source: .microphone, with: segments),
                    gate: progressGate,
                    token: progressGate.nextToken(for: transcriptionPhase),
                    progress: progress
                )
            }
            progressGate.advance()
            try Task.checkCancellation()
            let translationPhase = progressGate.currentPhase()
            let displayedSegments = TranscriptSegmentStore(transcriptSegments)
            let translatedSegments = try await translate(
                transcriptSegments,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            ) { segment in
                let segments = displayedSegments.upserting(segment)
                await reportProgress(
                    sessionByReplacingTranscriptSegments(in: session, source: .microphone, with: segments),
                    gate: progressGate,
                    token: progressGate.nextToken(for: translationPhase),
                    progress: progress
                )
            }
            progressGate.advance()
            try Task.checkCancellation()

            let updated = sessionByReplacingTranscriptSegments(
                in: session,
                source: .microphone,
                with: translatedSegments
            )
            return updated
        }

        public static func transcribeAudioFile(
            at url: URL,
            model: RecognitionModelDescriptor,
            sourceLanguage: SourceLanguageOption
        ) async throws -> String {
            switch model.runtime {
            case .appleSpeech:
                let recognizer = try speechRecognizer(for: sourceLanguage)
                return try await transcribe(url: url, recognizer: recognizer)
            case .fluidAudio:
                guard model.supports(sourceLanguage: sourceLanguage) else {
                    throw RealtimeHistoryAudioPostProcessorError.unsupportedRecognitionModel(model.title)
                }
                #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
                    return try await transcribeWithFluidAudio(
                        url: url,
                        model: model,
                        language: sourceLanguage
                    )
                #else
                    throw RealtimeHistoryAudioPostProcessorError.unsupportedRecognitionModel(model.title)
                #endif
            case .coreML, .mossOffline, .mlxStreaming, .onnx:
                throw RealtimeHistoryAudioPostProcessorError.unsupportedRecognitionModel(model.title)
            }
        }
    }

    extension RealtimeHistoryAudioPostProcessor {
        public static func mergingMicrophonePostProcessing(
            _ processed: RealtimeHistorySession,
            into current: RealtimeHistorySession
        ) -> RealtimeHistorySession {
            guard processed.requestID == current.requestID else { return current }
            var merged = current
            merged.delayedTranscriptSegments = (
                current.delayedTranscriptSegments.filter { $0.source != .microphone } +
                    processed.delayedTranscriptSegments.filter { $0.source == .microphone }
            )
            .sorted { lhs, rhs in
                if lhs.offset == rhs.offset {
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                return lhs.offset < rhs.offset
            }
            merged.transcriptionModels = current.transcriptionModels.filter { $0.source != .microphone } +
                processed.transcriptionModels.filter { $0.source == .microphone }
            merged.delayedConversationItems = RealtimeHistoryConversationBuilder.build(from: merged)
            return merged
        }

        static func translateTranscriptSegments(
            _ segments: [RealtimeHistoryTranscriptSegment],
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption,
            translateText: (String) async throws -> String,
            onSegmentTranslated: (RealtimeHistoryTranscriptSegment) async -> Void = { _ in }
        ) async throws -> [RealtimeHistoryTranscriptSegment] {
            try Task.checkCancellation()
            guard !segments.isEmpty else { return [] }
            guard sourceLanguage.rawValue != targetLanguage.rawValue else {
                var translated: [RealtimeHistoryTranscriptSegment] = []
                for segment in segments {
                    try Task.checkCancellation()
                    var segment = segment
                    segment.translatedText = segment.text
                    translated.append(segment)
                    try Task.checkCancellation()
                    await onSegmentTranslated(segment)
                }
                return translated
            }

            var translated: [RealtimeHistoryTranscriptSegment] = []
            for segment in segments {
                try Task.checkCancellation()
                var segment = segment
                var lastError: Error?
                for attempt in 1 ... translationAttemptLimit {
                    do {
                        segment.translatedText = try await translateText(segment.text)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        try Task.checkCancellation()
                        lastError = nil
                        break
                    } catch let error as CancellationError {
                        throw error
                    } catch {
                        lastError = error
                        if attempt < translationAttemptLimit {
                            try await Task.sleep(for: translationRetryDelay)
                        }
                    }
                }
                if let lastError {
                    logger.warning(
                        """
                        Realtime history translation skipped segment=\(segment.id.uuidString, privacy: .public) \
                        attempts=\(translationAttemptLimit, privacy: .public) error=\(
                            String(describing: lastError),
                            privacy: .public
                        )
                        """
                    )
                }
                try Task.checkCancellation()
                translated.append(segment)
                await onSegmentTranslated(segment)
            }
            return translated
        }
    }

    private extension RealtimeHistoryAudioPostProcessor {
        typealias TranscriptTextUpdate = (String) async -> Void
        typealias TranscriptSegmentUpdate = (RealtimeHistoryTranscriptSegment) async -> Void

        private static func transcribe(
            _ recordings: [RealtimeHistoryAudioRecording],
            language: SourceLanguageOption,
            recognitionModel: RecognitionModelDescriptor,
            onSegmentUpdate: @escaping TranscriptSegmentUpdate = { _ in }
        ) async throws -> [RealtimeHistoryTranscriptSegment] {
            switch recognitionModel.runtime {
            case .appleSpeech:
                return try await transcribeWithAppleSpeech(
                    recordings,
                    language: language,
                    onSegmentUpdate: onSegmentUpdate
                )
            case .fluidAudio:
                guard recognitionModel.supports(sourceLanguage: language) else {
                    return try await transcribeWithAppleSpeech(
                        recordings,
                        language: language,
                        onSegmentUpdate: onSegmentUpdate
                    )
                }
                #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
                    guard await RecognitionModelStore.shared.isModelCached(recognitionModel) else {
                        return try await transcribeWithAppleSpeech(
                            recordings,
                            language: language,
                            onSegmentUpdate: onSegmentUpdate
                        )
                    }
                    return try await transcribeWithFluidAudio(
                        recordings,
                        model: recognitionModel,
                        language: language,
                        onSegmentUpdate: onSegmentUpdate
                    )
                #else
                    throw RealtimeHistoryAudioPostProcessorError.unsupportedRecognitionModel(recognitionModel.title)
                #endif
            case .coreML, .mossOffline, .mlxStreaming, .onnx:
                throw RealtimeHistoryAudioPostProcessorError.unsupportedRecognitionModel(recognitionModel.title)
            }
        }

        private static func recognitionModel(for modelID: String) -> RecognitionModelDescriptor {
            RecognitionModelStore.selectableDescriptor(forModelID: modelID)
        }

        private static func resolvedRecognitionModel(
            for modelID: String,
            sourceLanguage: SourceLanguageOption
        ) async -> RecognitionModelDescriptor {
            let model = recognitionModel(for: modelID)
            guard model.runtime == .fluidAudio else { return model }
            guard model.supports(sourceLanguage: sourceLanguage) else { return .appleSpeech }
            #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
                return await RecognitionModelStore.shared.isModelCached(model) ? model : .appleSpeech
            #else
                return .appleSpeech
            #endif
        }

        private static func transcriptionModelMetadata(
            source: RealtimeHistoryAudioSource,
            model: RecognitionModelDescriptor
        ) -> RealtimeHistoryTranscriptionModel {
            RealtimeHistoryTranscriptionModel(source: source, modelID: model.id, modelDisplayName: model.title)
        }

        private static func sessionByReplacingTranscriptionModel(
            in session: RealtimeHistorySession,
            source: RealtimeHistoryAudioSource,
            model: RecognitionModelDescriptor
        ) -> RealtimeHistorySession {
            var updated = session
            updated.transcriptionModels = session.transcriptionModels.filter { $0.source != source } + [
                transcriptionModelMetadata(source: source, model: model),
            ]
            return updated
        }

        private static func sessionByReplacingTranscriptionModels(
            in session: RealtimeHistorySession,
            sources: Set<RealtimeHistoryAudioSource>,
            model: RecognitionModelDescriptor
        ) -> RealtimeHistorySession {
            guard !sources.isEmpty else { return session }
            var updated = session
            updated.transcriptionModels = session.transcriptionModels.filter { !sources.contains($0.source) } +
                sources.map { transcriptionModelMetadata(source: $0, model: model) }
            return updated
        }

        private static func sessionByReplacingTranscriptSegments(
            in session: RealtimeHistorySession,
            source: RealtimeHistoryAudioSource,
            with segments: [RealtimeHistoryTranscriptSegment]
        ) -> RealtimeHistorySession {
            var updated = session
            updated.delayedTranscriptSegments = (
                session.delayedTranscriptSegments.filter { $0.source != source } + segments
            )
            .sorted { lhs, rhs in
                if lhs.offset == rhs.offset {
                    return lhs.source.rawValue < rhs.source.rawValue
                }
                return lhs.offset < rhs.offset
            }
            updated.delayedConversationItems = RealtimeHistoryConversationBuilder.build(from: updated)
            return updated
        }

        private static func reportProgress(
            _ session: RealtimeHistorySession,
            gate: RealtimeHistoryProgressGate,
            token: RealtimeHistoryProgressGate.Token,
            progress: @escaping @MainActor (RealtimeHistorySession) -> Void
        ) async {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard gate.shouldPublish(token) else { return }
                progress(session)
            }
        }

        final class TranscriptSegmentStore: @unchecked Sendable {
            private let lock = NSLock()
            private var segments: [RealtimeHistoryTranscriptSegment]

            init(_ segments: [RealtimeHistoryTranscriptSegment] = []) {
                self.segments = segments
            }

            func upserting(_ segment: RealtimeHistoryTranscriptSegment) -> [RealtimeHistoryTranscriptSegment] {
                lock.lock()
                defer { lock.unlock() }

                if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                    segments[index] = segment
                } else {
                    segments.append(segment)
                }
                return segments.sorted { lhs, rhs in
                    if lhs.offset == rhs.offset {
                        return lhs.source.rawValue < rhs.source.rawValue
                    }
                    return lhs.offset < rhs.offset
                }
            }
        }

        final class SpeechRecognitionOperation: @unchecked Sendable {
            private let lock = NSLock()
            private let request: SFSpeechAudioBufferRecognitionRequest
            private var continuation: CheckedContinuation<String, Error>?
            private var completion: Result<String, Error>?
            private var latest = ""
            private var task: SFSpeechRecognitionTask?
            private var timeout: DispatchWorkItem?

            init(request: SFSpeechAudioBufferRecognitionRequest) {
                self.request = request
            }

            func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
                lock.lock()
                if let completion {
                    lock.unlock()
                    continuation.resume(with: completion)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }

            func setTask(_ task: SFSpeechRecognitionTask) {
                lock.lock()
                if completion == nil {
                    self.task = task
                    lock.unlock()
                } else {
                    lock.unlock()
                    task.cancel()
                }
            }

            func setTimeout(_ timeout: DispatchWorkItem) {
                lock.lock()
                if completion == nil {
                    self.timeout = timeout
                    lock.unlock()
                } else {
                    lock.unlock()
                    timeout.cancel()
                }
            }

            func updateLatest(_ text: String) {
                lock.lock()
                latest = text
                lock.unlock()
            }

            func currentLatest() -> String {
                lock.lock()
                defer { lock.unlock() }
                return latest
            }

            func complete(_ result: Result<String, Error>) {
                lock.lock()
                guard completion == nil else {
                    lock.unlock()
                    return
                }
                completion = result
                let continuation = continuation
                self.continuation = nil
                let task = task
                self.task = nil
                let timeout = timeout
                self.timeout = nil
                lock.unlock()

                timeout?.cancel()
                request.endAudio()
                task?.cancel()
                continuation?.resume(with: result)
            }
        }

        private static func transcribeSegments(
            _ recordings: [RealtimeHistoryAudioRecording],
            logLabel: String,
            onSegmentUpdate: @escaping TranscriptSegmentUpdate,
            transcribe: (URL, @escaping TranscriptTextUpdate) async throws -> String
        ) async throws -> [RealtimeHistoryTranscriptSegment] {
            var output: [RealtimeHistoryTranscriptSegment] = []
            var attemptedSegmentCount = 0
            for recording in recordings where recording.hasPlayableAudio {
                try Task.checkCancellation()
                for segment in recording.segments {
                    try Task.checkCancellation()
                    guard let url = RealtimeHistoryAudioStorage.fileURL(for: segment) else { continue }
                    attemptedSegmentCount += 1
                    let text: String
                    do {
                        let rawText = try await transcribe(url) { partialText in
                            let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            await onSegmentUpdate(RealtimeHistoryTranscriptSegment(
                                id: segment.id,
                                source: recording.source,
                                offset: segment.offset,
                                duration: segment.duration,
                                text: trimmed
                            ))
                        }
                        text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                    } catch let error as CancellationError {
                        throw error
                    } catch {
                        logger.warning(
                            """
                            \(logLabel, privacy: .public) skipped segment=\(segment.relativePath, privacy: .public) \
                            source=\(recording.source.rawValue, privacy: .public) error=\(
                                String(describing: error),
                                privacy: .public
                            )
                            """
                        )
                        continue
                    }
                    guard !text.isEmpty else { continue }
                    let transcriptSegment = RealtimeHistoryTranscriptSegment(
                        id: segment.id,
                        source: recording.source,
                        offset: segment.offset,
                        duration: segment.duration,
                        text: text
                    )
                    output.append(transcriptSegment)
                    try Task.checkCancellation()
                    await onSegmentUpdate(transcriptSegment)
                }
            }
            if output.isEmpty, attemptedSegmentCount > 0 {
                throw RealtimeHistoryAudioPostProcessorError.speechNotRecognized
            }
            return output.sorted { $0.offset < $1.offset }
        }

        private static func transcribeWithAppleSpeech(
            _ recordings: [RealtimeHistoryAudioRecording],
            language: SourceLanguageOption,
            onSegmentUpdate: @escaping TranscriptSegmentUpdate = { _ in }
        ) async throws -> [RealtimeHistoryTranscriptSegment] {
            guard await speechAuthorizationGranted() else {
                throw RealtimeHistoryAudioPostProcessorError.speechNotAuthorized
            }
            let recognizer = try speechRecognizer(for: language)

            return try await transcribeSegments(
                recordings,
                logLabel: "Realtime history transcription",
                onSegmentUpdate: onSegmentUpdate
            ) { url, onPartial in
                try await transcribe(url: url, recognizer: recognizer, onPartial: onPartial)
            }
        }

        #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
            private static func transcribeWithFluidAudio(
                _ recordings: [RealtimeHistoryAudioRecording],
                model: RecognitionModelDescriptor,
                language: SourceLanguageOption,
                onSegmentUpdate: @escaping TranscriptSegmentUpdate = { _ in }
            ) async throws -> [RealtimeHistoryTranscriptSegment] {
                try await transcribeSegments(
                    recordings,
                    logLabel: "Realtime history FluidAudio transcription",
                    onSegmentUpdate: onSegmentUpdate
                ) { url, _ in
                    try await transcribeWithFluidAudio(
                        url: url,
                        model: model,
                        language: language
                    )
                }
            }

            private static func transcribeWithFluidAudio(
                url: URL,
                model: RecognitionModelDescriptor,
                language: SourceLanguageOption
            ) async throws -> String {
                guard case let .fluidAudio(fluidAudioModel) = model.download else {
                    throw RealtimeHistoryAudioPostProcessorError.unsupportedRecognitionModel(model.title)
                }

                let modelDirectory = await RecognitionModelStore.shared.cachedModelURL(for: model)
                switch fluidAudioModel {
                case .parakeetEOU320, .parakeetEOU1280:
                    let manager = StreamingEouAsrManager(
                        chunkSize: fluidAudioModel == .parakeetEOU320 ? .ms320 : .ms1280
                    )
                    try await manager.loadModels(to: modelDirectory)
                    try await forEachAudioBuffer(at: url) { buffer in
                        try await manager.appendAudio(buffer)
                        try await manager.processBufferedAudio()
                    }
                    return try await manager.finish()
                case .nemotronStreaming560, .nemotronStreaming1120, .nemotronStreaming2240:
                    let chunkSize: NemotronChunkSize = switch fluidAudioModel {
                    case .nemotronStreaming560: .ms560
                    case .nemotronStreaming1120: .ms1120
                    default: .ms2240
                    }
                    let manager = StreamingNemotronAsrManager(
                        requestedChunkSize: chunkSize
                    )
                    try await manager.loadModels(
                        from: modelDirectory.appendingPathComponent(chunkSize.repo.folderName, isDirectory: true)
                    )
                    try await forEachAudioBuffer(at: url) { buffer in
                        try await manager.appendAudio(buffer)
                        try await manager.processBufferedAudio()
                    }
                    return try await manager.finish()
                case .nemotronMultilingual2240:
                    let manager = StreamingNemotronMultilingualAsrManager()
                    try await manager.loadModels(
                        from: modelDirectory
                            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
                            .appendingPathComponent("multilingual/2240ms", isDirectory: true)
                    )
                    await manager.setLanguage(
                        language == .auto
                            ? "auto"
                            : RealtimeFluidAudioLanguageMapper.nemotronLanguageCode(language.rawValue)
                    )
                    try await forEachAudioBuffer(at: url) { buffer in
                        _ = try await manager.process(audioBuffer: buffer)
                    }
                    return try await manager.finish()
                }
            }

            private static func forEachAudioBuffer(
                at url: URL,
                _ body: (AVAudioPCMBuffer) async throws -> Void
            ) async throws {
                let audioFile = try AVAudioFile(forReading: url)
                while audioFile.framePosition < audioFile.length {
                    try Task.checkCancellation()
                    let remainingFrames = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
                    let frameCount = min(audioReadFrameCapacity, remainingFrames)
                    guard let buffer = AVAudioPCMBuffer(
                        pcmFormat: audioFile.processingFormat,
                        frameCapacity: frameCount
                    ) else {
                        throw RealtimeHistoryAudioPostProcessorError.audioFileUnreadable
                    }
                    try audioFile.read(into: buffer, frameCount: frameCount)
                    guard buffer.frameLength > 0 else { break }
                    try await body(buffer)
                }
            }

            private static func readFloatSamples(from url: URL) async throws -> [Float] {
                let converter = RealtimePCMBufferConverter(commonFormat: .pcmFormatFloat32)
                var samples: [Float] = []
                try await forEachAudioBuffer(at: url) { buffer in
                    try Task.checkCancellation()
                    guard let converted = converter?.pcmBuffer(from: buffer),
                          let channelData = converted.floatChannelData
                    else {
                        return
                    }
                    samples.append(contentsOf: UnsafeBufferPointer(
                        start: channelData[0],
                        count: Int(converted.frameLength)
                    ))
                }
                return samples
            }
        #endif

        private static func speechRecognizer(for language: SourceLanguageOption) throws -> SFSpeechRecognizer {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
                  recognizer.isAvailable
            else {
                throw RealtimeHistoryAudioPostProcessorError.speechRecognizerUnavailable
            }
            return recognizer
        }

        private static func transcribe(
            url: URL,
            recognizer: SFSpeechRecognizer,
            onPartial: @escaping TranscriptTextUpdate = { _ in }
        ) async throws -> String {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            let operation = SpeechRecognitionOperation(request: request)

            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    operation.setContinuation(continuation)

                    let timeout = DispatchWorkItem {
                        let latest = operation.currentLatest().trimmingCharacters(in: .whitespacesAndNewlines)
                        if latest.isEmpty {
                            operation.complete(.failure(
                                RealtimeHistoryAudioPostProcessorError.speechRecognitionTimedOut
                            ))
                        } else {
                            operation.complete(.success(latest))
                        }
                    }
                    operation.setTimeout(timeout)

                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let result {
                            let latest = result.bestTranscription.formattedString
                            operation.updateLatest(latest)
                            Task {
                                await onPartial(latest)
                            }
                            if result.isFinal {
                                operation.complete(.success(latest))
                            }
                        }
                        if let error {
                            operation.complete(.failure(error))
                        }
                    }
                    operation.setTask(task)
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.recognitionTimeout, execute: timeout)

                    do {
                        try appendAudio(from: url, to: request)
                        request.endAudio()
                    } catch {
                        operation.complete(.failure(error))
                    }
                }
            } onCancel: {
                operation.complete(.failure(CancellationError()))
            }
        }

        private static func appendAudio(from url: URL, to request: SFSpeechAudioBufferRecognitionRequest) throws {
            let audioFile = try AVAudioFile(forReading: url)
            while audioFile.framePosition < audioFile.length {
                try Task.checkCancellation()
                let frameCount = min(audioReadFrameCapacity, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                    throw RealtimeHistoryAudioPostProcessorError.audioFileUnreadable
                }
                try audioFile.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else { break }
                request.append(buffer)
            }
        }

        private static func translate(
            _ segments: [RealtimeHistoryTranscriptSegment],
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption,
            onSegmentTranslated: @escaping TranscriptSegmentUpdate = { _ in }
        ) async throws -> [RealtimeHistoryTranscriptSegment] {
            try await translateTranscriptSegments(
                segments,
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
                onSegmentTranslated: onSegmentTranslated
            )
        }

        private static func speechAuthorizationGranted() async -> Bool {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                return true
            case .notDetermined:
                return await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status == .authorized)
                    }
                }
            case .denied, .restricted:
                return false
            @unknown default:
                return false
            }
        }
    }

    final class RealtimeHistoryProgressGate: @unchecked Sendable {
        struct Token: Sendable {
            let phase: Int
            let sequence: Int
        }

        private let lock = NSLock()
        private var phase = 0
        private var nextSequence = 0
        private var latestPublishedSequence = -1

        func currentPhase() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return phase
        }

        func nextToken(for phase: Int) -> Token {
            lock.lock()
            defer { lock.unlock() }
            let token = Token(phase: phase, sequence: nextSequence)
            nextSequence += 1
            return token
        }

        func advance() {
            lock.lock()
            phase += 1
            latestPublishedSequence = -1
            lock.unlock()
        }

        func invalidate() {
            advance()
        }

        func shouldPublish(_ token: Token) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard token.phase == phase, token.sequence > latestPublishedSequence else { return false }
            latestPublishedSequence = token.sequence
            return true
        }
    }

    public enum RealtimeHistoryAudioPostProcessorError: LocalizedError, Equatable {
        case microphoneRecordingUnavailable
        case speechNotAuthorized
        case speechRecognizerUnavailable
        case speechRecognitionTimedOut
        case speechNotRecognized
        case audioFileUnreadable
        case unsupportedLanguage
        case unsupportedRecognitionModel(String)

        public var errorDescription: String? {
            switch self {
            case .microphoneRecordingUnavailable:
                return String(localized: "No microphone recording is available for this history item.")
            case .speechNotAuthorized:
                return String(localized: "Speech Recognition permission is required to translate recordings.")
            case .speechRecognizerUnavailable:
                return String(localized: "Speech Recognition is unavailable for this recording.")
            case .speechRecognitionTimedOut:
                return String(localized: "Speech Recognition timed out for this recording.")
            case .speechNotRecognized:
                return String(localized: "No speech was recognized in the microphone recording.")
            case .audioFileUnreadable:
                return String(localized: "The recording audio file could not be read.")
            case .unsupportedLanguage:
                return String(localized: "This history language pair cannot be processed.")
            case let .unsupportedRecognitionModel(model):
                return String(localized: "The selected recognition model cannot process this recording: \(model).")
            }
        }
    }
#endif
