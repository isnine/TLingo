#if os(macOS) && arch(arm64) && canImport(MLXAudioSTT)
    import AVFoundation
    import CoreMedia
    import Foundation
    import HuggingFace
    import MLX
    import MLXAudioSTT
    import Tokenizers

    /// Port of Confucius4-R2T2 `streaming_transcribe_no_reset`: re-feeds a rolling audio window with the
    /// committed text as the assistant prefix and only appends the stable prefix of each decode step.
    final class RealtimeR2T2Recognizer: @unchecked Sendable, RealtimeRecognizer {
        private struct ChunkText {
            let sampleCount: Int
            let text: String
        }

        private static let stepSampleCount = 2560
        private static let maximumStepSampleCount = 32000
        private static let windowSampleCount = 16 * 16000
        private static let discardSampleCount = 8 * 16000
        private static let maximumPendingSampleCount = 15 * 16000
        private static let unfixedTokenCount = 1
        private static let tokensPerStep = 4
        private static let finalMaxTokens = 64
        private static let eosTokenIDs: Set<Int> = [151_645, 151_643]
        private static let asrTextTag = "<asr_text>"
        // Each step has a different window shape, so MLX's buffer cache otherwise grows past 10 GB.
        private static let mlxCacheLimit = 512 * 1024 * 1024

        var onResult: ((UUID, RealtimeRecognitionResult) -> Void)?
        var onFailure: ((UUID, Error) -> Void)?

        var sampleRate: Int { 16000 }

        private let lock = NSLock()
        private let conversionLock = NSLock()
        private let converter = RealtimePCMBufferConverter(commonFormat: .pcmFormatFloat32)!

        private var pendingSamples: [Float] = []
        private var processingTask: Task<Void, Never>?
        private var isPaused = false
        private var isStopping = true
        private var hasReportedFailure = false
        private var activeSessionID = UUID()

        // Decoder state is only touched by the serial processing task, or by stop() after it finished.
        private var model: Qwen3ASRModel?
        private var forcedLanguage: String?
        private var detectedLanguage = ""
        private var audioWindow: [Float] = []
        private var chunkTexts: [ChunkText] = []
        private var unfixedText = ""
        private var unsegmentedText = ""
        private var stableSegments: [RealtimeRecognitionSegment] = []
        private var pendingSegmentID = UUID()
        private var segmentStartOffset: TimeInterval = 0
        private var processedSampleCount = 0
        private var lastPublishedText = ""

        func start(model descriptor: RecognitionModelDescriptor, locale: Locale, sessionID: UUID) async throws {
            await stop()
            let cacheURL = await RecognitionModelStore.shared.cachedModelURL(for: descriptor)
            guard descriptor.runtime == .mlxStreaming,
                  let snapshotURL = Self.snapshotDirectory(in: cacheURL)
            else {
                throw RealtimeRecognizerError.unsupportedModel(descriptor.id)
            }
            Memory.cacheLimit = Self.mlxCacheLimit
            let model = try await Qwen3ASRModel.fromModelDirectory(snapshotURL)
            self.model = model
            forcedLanguage = Self.forcedLanguage(for: locale, supportedLanguages: model.config.supportLanguages)
            lock.withLock {
                isStopping = false
                isPaused = false
                hasReportedFailure = false
                activeSessionID = sessionID
            }
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            conversionLock.lock()
            let pcmBuffer = converter.pcmBuffer(from: sampleBuffer)
            conversionLock.unlock()
            guard let pcmBuffer else { return }
            append(Self.samples(from: pcmBuffer))
        }

        func append(_ pcmBuffer: AVAudioPCMBuffer) {
            conversionLock.lock()
            let convertedBuffer = converter.pcmBuffer(from: pcmBuffer)
            conversionLock.unlock()
            guard let convertedBuffer else { return }
            append(Self.samples(from: convertedBuffer))
        }

        func append(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            lock.lock()
            guard !isPaused, !isStopping else {
                lock.unlock()
                return
            }
            guard pendingSamples.count + samples.count <= Self.maximumPendingSampleCount else {
                isPaused = true
                let sessionID = activeSessionID
                lock.unlock()
                reportFailure(RealtimeRecognizerError.audioBacklogExceeded, sessionID: sessionID)
                return
            }
            pendingSamples.append(contentsOf: samples)
            if processingTask == nil, pendingSamples.count >= Self.stepSampleCount {
                let sessionID = activeSessionID
                processingTask = Task { [weak self] in
                    await self?.processPendingAudio(sessionID: sessionID)
                }
            }
            lock.unlock()
        }

        func setPaused(_ isPaused: Bool) {
            lock.withLock {
                self.isPaused = isPaused
            }
        }

        func stop() async {
            let (task, sessionID) = lock.withLock {
                isStopping = true
                return (processingTask, activeSessionID)
            }
            await task?.value
            let remainingSamples = lock.withLock {
                let samples = pendingSamples
                pendingSamples.removeAll()
                processingTask = nil
                return samples
            }

            if model != nil, !(remainingSamples.isEmpty && audioWindow.isEmpty) {
                decodeStep(remainingSamples, maxNewTokens: Self.finalMaxTokens, unfixedTokenCount: 0)
                commitPendingSegment(boundaryReason: .terminal)
                publishSnapshot(sessionID: sessionID, isTerminal: true)
            }

            model = nil
            forcedLanguage = nil
            detectedLanguage = ""
            audioWindow.removeAll()
            chunkTexts.removeAll()
            unfixedText = ""
            unsegmentedText = ""
            stableSegments.removeAll()
            pendingSegmentID = UUID()
            segmentStartOffset = 0
            processedSampleCount = 0
            lastPublishedText = ""
            Memory.clearCache()
        }
    }

    extension RealtimeR2T2Recognizer {
        static func downloadSnapshot(
            repoID: String,
            to directory: URL,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            guard let repositoryID = Repo.ID(rawValue: repoID) else {
                throw RealtimeRecognizerError.unsupportedModel(repoID)
            }
            _ = try await HubClient(cache: HubCache(cacheDirectory: directory)).downloadSnapshot(
                of: repositoryID,
                progressHandler: { downloadProgress in
                    progress(min(max(downloadProgress.fractionCompleted, 0), 1))
                }
            )
        }
    }

    private extension RealtimeR2T2Recognizer {
        static func snapshotDirectory(in cacheURL: URL) -> URL? {
            let enumerator = FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: nil)
            return enumerator?.compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "config.json" && $0.path.contains("/snapshots/") }?
                .deletingLastPathComponent()
        }

        func processPendingAudio(sessionID: UUID) async {
            while true {
                let samples = lock.withLock { () -> [Float]? in
                    guard !isStopping, sessionID == activeSessionID,
                          pendingSamples.count >= Self.stepSampleCount
                    else {
                        processingTask = nil
                        return nil
                    }
                    let available = min(pendingSamples.count, Self.maximumStepSampleCount)
                    let count = available - available % Self.stepSampleCount
                    let samples = Array(pendingSamples.prefix(count))
                    pendingSamples.removeFirst(count)
                    return samples
                }
                guard let samples else { return }
                let stepCount = samples.count / Self.stepSampleCount
                decodeStep(
                    samples,
                    maxNewTokens: Self.tokensPerStep * stepCount,
                    unfixedTokenCount: Self.unfixedTokenCount
                )
                publishSnapshot(sessionID: sessionID, isTerminal: false)
                await Task.yield()
            }
        }

        func decodeStep(_ samples: [Float], maxNewTokens: Int, unfixedTokenCount: Int) {
            guard let model, let tokenizer = model.tokenizer else { return }
            audioWindow.append(contentsOf: samples)
            processedSampleCount += samples.count
            if audioWindow.count > Self.windowSampleCount {
                audioWindow.removeFirst(Self.discardSampleCount)
                var discardedSampleCount = 0
                while let first = chunkTexts.first,
                      discardedSampleCount + first.sampleCount <= Self.discardSampleCount
                {
                    discardedSampleCount += first.sampleCount
                    chunkTexts.removeFirst()
                }
            }
            guard !audioWindow.isEmpty else { return }

            let prefixText = chunkTexts.map(\.text).joined()
            let languagePrefix = forcedLanguage == nil && !detectedLanguage.isEmpty
                ? "language \(detectedLanguage)\(Self.asrTextTag)"
                : ""
            let prefix = Self.beforeStableMarker(languagePrefix + prefixText)

            let generated = Self.normalizedPunctuation(
                generate(model: model, tokenizer: tokenizer, prefix: prefix, maxNewTokens: maxNewTokens)
            ).replacingOccurrences(of: "\u{FFFD}", with: "")
            let parsed = parse(prefix + generated)
            let hasTag = forcedLanguage == nil && (prefix + generated).contains(Self.asrTextTag)
            guard forcedLanguage != nil || hasTag else {
                unfixedText = ""
                chunkTexts.append(ChunkText(sampleCount: samples.count, text: ""))
                return
            }

            let raw = Self.beforeStableMarker(
                hasTag ? "language \(parsed.language)\(Self.asrTextTag)\(parsed.text)" : parsed.text
            )
            let rawTokenIDs = tokenizer.encode(text: raw, addSpecialTokens: false)
            let windowText = Self.beforeStableMarker(parsed.text)
            var rollbackCount = hasTag && windowText.isEmpty ? 0 : unfixedTokenCount
            var fixedText = ""
            while true {
                let endIndex = max(0, rawTokenIDs.count - rollbackCount)
                fixedText = endIndex > 0 ? tokenizer.decode(tokens: Array(rawTokenIDs.prefix(endIndex))) : ""
                guard fixedText.contains("\u{FFFD}"), endIndex > 0 else { break }
                rollbackCount += 1
            }
            if hasTag {
                fixedText = fixedText.range(of: Self.asrTextTag).map { String(fixedText[$0.upperBound...]) } ?? ""
            }

            detectedLanguage = parsed.language
            let stablePrefix = prefixText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableFixedText = fixedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = stableFixedText.hasPrefix(stablePrefix)
                ? Self.beforeStableMarker(String(stableFixedText.dropFirst(stablePrefix.count)))
                : ""
            chunkTexts.append(ChunkText(sampleCount: samples.count, text: newText))

            unfixedText = windowText.hasPrefix(stableFixedText)
                ? String(windowText.dropFirst(stableFixedText.count))
                : ""
            unsegmentedText += newText
            segmentCompletedSentences()
        }

        func generate(
            model: Qwen3ASRModel,
            tokenizer: any Tokenizer,
            prefix: String,
            maxNewTokens: Int
        ) -> String {
            let (inputFeatures, featureAttentionMask, audioTokenCount) = model.preprocessAudio(MLXArray(audioWindow))
            let prompt = "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>"
                + String(repeating: "<|audio_pad|>", count: audioTokenCount)
                + "<|audio_end|><|im_end|>\n<|im_start|>assistant\n"
                + (forcedLanguage.map { "language \($0)\(Self.asrTextTag)" } ?? "")
                + prefix
            let inputIDs = MLXArray(tokenizer.encode(text: prompt).map { Int32($0) }).expandedDimensions(axis: 0)
            let cache = model.makeCache()
            var logits = model(
                inputIds: inputIDs,
                inputFeatures: inputFeatures,
                featureAttentionMask: featureAttentionMask,
                cache: cache
            )
            var generatedTokenIDs: [Int] = []
            while true {
                let tokenID = logits[0..., -1, 0...].argMax(axis: -1).item(Int.self)
                guard !Self.eosTokenIDs.contains(tokenID) else { break }
                generatedTokenIDs.append(tokenID)
                guard generatedTokenIDs.count < maxNewTokens else { break }
                logits = model(inputIds: MLXArray([Int32(tokenID)]).expandedDimensions(axis: 0), cache: cache)
            }
            return tokenizer.decode(tokens: generatedTokenIDs)
        }

        func parse(_ raw: String) -> (language: String, text: String) {
            let language: String
            var text: String
            if let forcedLanguage {
                language = forcedLanguage
                text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let tagRange = raw.range(of: Self.asrTextTag) {
                let meta = raw[..<tagRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let name = meta.hasPrefix("language ") ? String(meta.dropFirst("language ".count)) : ""
                language = name.lowercased() == "none" ? "" : name
                text = raw[tagRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                language = ""
                text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if language == "Chinese" {
                text = text.replacingOccurrences(
                    of: "(?<=[\\u4e00-\\u9fff])\\s+(?=[\\u4e00-\\u9fff])",
                    with: "",
                    options: .regularExpression
                )
            }
            return (language, text)
        }

        func segmentCompletedSentences() {
            let split = RealtimeTranscriptSegmenter.completedSegmentsAndPending(from: unsegmentedText)
            guard !split.segments.isEmpty else { return }
            let endOffset = Double(processedSampleCount) / Double(sampleRate)
            let duration = max(0, endOffset - segmentStartOffset) / Double(split.segments.count)
            for (index, text) in split.segments.enumerated() {
                stableSegments.append(RealtimeRecognitionSegment(
                    id: index == 0 ? pendingSegmentID : UUID(),
                    text: text,
                    startOffset: segmentStartOffset + duration * Double(index),
                    endOffset: segmentStartOffset + duration * Double(index + 1),
                    boundaryReason: .punctuation
                ))
            }
            pendingSegmentID = UUID()
            segmentStartOffset = endOffset
            unsegmentedText = split.pending
        }

        func commitPendingSegment(boundaryReason: RealtimeRecognitionBoundaryReason) {
            let text = (unsegmentedText + unfixedText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let endOffset = Double(processedSampleCount) / Double(sampleRate)
            stableSegments.append(RealtimeRecognitionSegment(
                id: pendingSegmentID,
                text: text,
                startOffset: segmentStartOffset,
                endOffset: endOffset,
                boundaryReason: boundaryReason
            ))
            pendingSegmentID = UUID()
            segmentStartOffset = endOffset
            unsegmentedText = ""
            unfixedText = ""
        }

        func publishSnapshot(sessionID: UUID, isTerminal: Bool) {
            let pendingText = (unsegmentedText + unfixedText).trimmingCharacters(in: .whitespacesAndNewlines)
            let audioOffset = Double(processedSampleCount) / Double(sampleRate)
            let snapshot = RealtimeRecognitionSnapshot(
                stableSegments: stableSegments,
                pendingSegment: pendingText.isEmpty ? nil : RealtimeRecognitionSegment(
                    id: pendingSegmentID,
                    text: pendingText,
                    startOffset: segmentStartOffset,
                    endOffset: audioOffset,
                    boundaryReason: .stableWindow
                ),
                audioOffset: audioOffset,
                isTerminal: isTerminal
            )
            guard !snapshot.visibleText.isEmpty,
                  isTerminal || snapshot.visibleText != lastPublishedText
            else { return }
            lastPublishedText = snapshot.visibleText
            onResult?(sessionID, RealtimeRecognitionResult(snapshot: snapshot))
        }

        func reportFailure(_ error: Error, sessionID: UUID) {
            let shouldReport = lock.withLock { () -> Bool in
                guard !isStopping, sessionID == activeSessionID, !hasReportedFailure else { return false }
                hasReportedFailure = true
                return true
            }
            if shouldReport {
                onFailure?(sessionID, error)
            }
        }

        static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
            guard let channelData = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        static func beforeStableMarker(_ text: String) -> String {
            text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        }

        static func forcedLanguage(for locale: Locale, supportedLanguages: [String]) -> String? {
            guard locale.identifier != "und", let code = locale.language.languageCode?.identifier else {
                return nil
            }
            let name = code == "yue" ? "Cantonese" : Locale(identifier: "en").localizedString(forLanguageCode: code)
            return name.flatMap { supportedLanguages.contains($0) ? $0 : nil }
        }

        static func normalizedPunctuation(_ text: String) -> String {
            let chinesePunctuation: [Character: Character] = [
                ",": "，", ".": "。", "!": "！", "?": "？", ";": "；", ":": "：", "(": "（", ")": "）",
            ]
            let englishPunctuation = Dictionary(uniqueKeysWithValues: chinesePunctuation.map { ($1, $0) })
            var result: [Character] = []
            for character in text {
                guard chinesePunctuation[character] != nil || englishPunctuation[character] != nil,
                      let previous = result.last(where: { !$0.isWhitespace })
                else {
                    result.append(character)
                    continue
                }
                if let scalar = previous.unicodeScalars.first, (0x4E00 ... 0x9FFF).contains(scalar.value) {
                    result.append(chinesePunctuation[character] ?? character)
                } else if previous.isASCII, previous.isLetter || previous.isNumber || previous == "\"" || previous == "'" {
                    result.append(englishPunctuation[character] ?? character)
                } else {
                    result.append(character)
                }
            }
            return String(result)
        }
    }
#endif
