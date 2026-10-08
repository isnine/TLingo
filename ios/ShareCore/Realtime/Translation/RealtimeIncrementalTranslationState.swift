#if os(macOS) || os(iOS)
    import Foundation
    import Synchronization

    struct RealtimeTextTranslationRequest {
        let translationText: String
        let cacheKey: String
        let cadenceInterval: TimeInterval
        let provider: RealtimeTranslationProvider
        let sourceLanguage: SourceLanguageOption
        let source: Locale.Language?
        let targetLanguage: TargetLanguageOption
    }

    struct RealtimeIncrementalTranslationState {
        // Bounded memory cache that lets re-displayed segments skip re-translation. It may be
        // smaller than a long session's segment count: display and dedup both fall back to the
        // currently displayed `sentencePairs`, so eviction only lowers the cache-hit rate.
        private static let translatedPairCacheLimit = 120

        private(set) var translationSourceText = ""
        private(set) var pendingSourceText = ""
        private(set) var translatedText = ""
        private(set) var sentencePairs: [SentencePair] = []
        private(set) var pendingTranslatedText = ""
        private(set) var sourceSegments: [String] = []

        private var translatedPairsBySource: [String: SentencePair] = [:]
        private var translatedPairKeyOrder: [String] = []
        private var finalizedPreviewPairsBySource: [String: SentencePair] = [:]
        private var queuedFinalTranslationKeys: Set<String> = []
        private var partialTranslationSourceTracker = RealtimeTranslationSourceTracker()

        mutating func reset() {
            translationSourceText = ""
            pendingSourceText = ""
            sourceSegments = []
            resetTranslationResults()
        }

        mutating func resetTranslationResults() {
            translatedText = ""
            sentencePairs = []
            pendingTranslatedText = ""
            translatedPairsBySource.removeAll()
            translatedPairKeyOrder.removeAll()
            finalizedPreviewPairsBySource.removeAll()
            queuedFinalTranslationKeys.removeAll()
            partialTranslationSourceTracker.reset()
        }

        mutating func updateSources(from transcript: RealtimeTranscriptAccumulator) {
            updateSources(
                committedText: transcript.committedText,
                pendingText: transcript.partialText
            )
        }

        mutating func updateSources(committedText: String, pendingText: String) {
            let previousStableText = translationSourceText
            let previousStableSegments = sourceSegments
            let previousSentencePairs = sentencePairs
            let previousPendingSource = pendingSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousPendingTranslation = pendingTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hadPendingSource = !previousPendingSource.isEmpty
            let sourceParts = Self.sourceParts(committedText: committedText, pendingText: pendingText)
            translationSourceText = sourceParts.stableText
            pendingSourceText = sourceParts.pendingText

            updateSourceSegments(previousStableText: previousStableText)
            if let finalizedPreviewPair = Self.finalizedPreviewPair(
                previousPendingSource: previousPendingSource,
                previousPendingTranslation: previousPendingTranslation,
                previousStableSegments: previousStableSegments,
                currentStableSegments: sourceSegments
            ) {
                RealtimeLog.log(
                    "align",
                    """
                    pending promoted to stable with preview translation \
                    src=\(RealtimeLog.text(finalizedPreviewPair.original)) tr=\(RealtimeLog.text(finalizedPreviewPair.translation))
                    """
                )
                finalizedPreviewPairsBySource[Self.normalizedSourceKey(finalizedPreviewPair.original)] = finalizedPreviewPair
            }
            let rollbackPreviewTranslation = Self.rollbackPreviewTranslation(
                previousStableSegments: previousStableSegments,
                previousSentencePairs: previousSentencePairs,
                currentStableSegments: sourceSegments,
                currentPendingSource: pendingSourceText
            )
            pruneFinalizedPreviewPairs(to: sourceSegments)
            refreshDisplayedSentencePairs(using: sourceSegments)

            if let rollbackPreviewTranslation {
                RealtimeLog.warn(
                    "align",
                    """
                    stable segment rolled back to pending, reusing its translation \
                    pending=\(RealtimeLog.text(pendingSourceText)) tr=\(RealtimeLog.text(rollbackPreviewTranslation))
                    """
                )
                pendingTranslatedText = rollbackPreviewTranslation
            } else if pendingSourceText.isEmpty ||
                !hadPendingSource ||
                !Self.isLikelyRevision(previousPendingSource, replacement: pendingSourceText)
            {
                pendingTranslatedText = ""
            }
        }

        mutating func clearStableTranslation() {
            sentencePairs = []
            translatedText = ""
            finalizedPreviewPairsBySource.removeAll()
        }

        mutating func applySameLanguageTranslation() {
            translatedText = translationSourceText
            sentencePairs = sourceSegments.map { SentencePair(original: $0, translation: $0) }
            pendingTranslatedText = pendingSourceText
            finalizedPreviewPairsBySource.removeAll()
        }

        mutating func makeFinalTranslationRequests(
            provider: RealtimeTranslationProvider,
            sourceLanguage: SourceLanguageOption,
            source: Locale.Language?,
            targetLanguage: TargetLanguageOption
        ) -> [RealtimeTextTranslationRequest] {
            // A segment shown with a finalized translation must not be re-translated even after its
            // cache entry is evicted, otherwise long sessions churn endlessly (evict -> re-translate
            // -> re-evict) and the captions flicker between source-only and bilingual.
            let alreadyTranslatedSourceKeys = displayedFinalTranslatedSourceKeys()
            var requests: [RealtimeTextTranslationRequest] = []
            for segment in sourceSegments {
                let key = translationPairCacheKey(
                    segment,
                    provider: provider,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                // Insert the key immediately so identical segments within one transcript (e.g. repeated
                // "Cool.") are not enqueued more than once.
                guard translatedPairsBySource[key] == nil,
                      !queuedFinalTranslationKeys.contains(key),
                      !alreadyTranslatedSourceKeys.contains(Self.normalizedSourceKey(segment))
                else {
                    continue
                }
                queuedFinalTranslationKeys.insert(key)
                requests.append(RealtimeTextTranslationRequest(
                    translationText: segment,
                    cacheKey: key,
                    cadenceInterval: RealtimeTranslationSchedulingPolicy.cadenceInterval(for: provider),
                    provider: provider,
                    sourceLanguage: sourceLanguage,
                    source: source,
                    targetLanguage: targetLanguage
                ))
            }
            return requests
        }

        /// Normalized source keys for segments whose finalized translation is already on screen.
        /// Preview-only pairs are excluded so the final translation path still replaces them.
        private func displayedFinalTranslatedSourceKeys() -> Set<String> {
            let previewKeys = Set(finalizedPreviewPairsBySource.keys)
            return Set(
                sentencePairs
                    .filter { !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { Self.normalizedSourceKey($0.original) }
                    .filter { !previewKeys.contains($0) }
            )
        }

        mutating func makePartialTranslationRequest(
            provider: RealtimeTranslationProvider,
            sourceLanguage: SourceLanguageOption,
            source: Locale.Language?,
            targetLanguage: TargetLanguageOption
        ) -> RealtimeTextTranslationRequest? {
            let partial = pendingSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !partial.isEmpty else {
                partialTranslationSourceTracker.reset()
                return nil
            }

            let cacheKey = translationPairCacheKey(
                partial,
                provider: provider,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            guard partialTranslationSourceTracker.shouldSchedule(cacheKey) else { return nil }

            return RealtimeTextTranslationRequest(
                translationText: partial,
                cacheKey: cacheKey,
                cadenceInterval: RealtimeTranslationSchedulingPolicy.cadenceInterval(for: provider),
                provider: provider,
                sourceLanguage: sourceLanguage,
                source: source,
                targetLanguage: targetLanguage
            )
        }

        mutating func finishFinalTranslationRequest(_ request: RealtimeTextTranslationRequest) {
            queuedFinalTranslationKeys.remove(request.cacheKey)
        }

        mutating func cancelQueuedFinalTranslationRequests() {
            queuedFinalTranslationKeys.removeAll()
        }

        mutating func applyFinalTranslationSuccess(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) -> Bool {
            finishFinalTranslationRequest(request)
            guard case let .success(text) = result.response else { return false }

            let combinedTranslation = translatedText(
                from: result,
                fallbackTranslation: text,
                request: request
            )
            finalizedPreviewPairsBySource.removeValue(forKey: Self.normalizedSourceKey(request.translationText))
            cacheTranslatedSentencePair(SentencePair(
                original: request.translationText,
                translation: combinedTranslation
            ), cacheKey: request.cacheKey)
            updateCachedSentencePairs(
                provider: request.provider,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage
            )
            if pendingSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingTranslatedText = ""
            }
            return true
        }

        mutating func applyPartialTranslationSuccess(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) -> Bool {
            let currentKey = translationPairCacheKey(
                pendingSourceText,
                provider: request.provider,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage
            )
            guard currentKey == request.cacheKey,
                  case let .success(text) = result.response
            else {
                return false
            }

            pendingTranslatedText = translatedText(
                from: result,
                fallbackTranslation: text,
                request: request
            )
            return true
        }

        mutating func updateCachedSentencePairs(
            provider: RealtimeTranslationProvider,
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption
        ) {
            guard !sourceSegments.isEmpty else {
                clearStableTranslation()
                return
            }

            var existingPairsBySource = Dictionary(grouping: sentencePairs) { Self.normalizedSourceKey($0.original) }
            let displayedPairs = sourceSegments.compactMap { segment in
                let finalPair = translatedPairsBySource[translationPairCacheKey(
                    segment,
                    provider: provider,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )]
                return finalPair ?? displayedPair(forSegment: segment, consuming: &existingPairsBySource)
            }
            assignDisplayedPairs(displayedPairs)
        }

        private mutating func refreshDisplayedSentencePairs(using sourceSegments: [String]) {
            guard !sourceSegments.isEmpty else {
                clearStableTranslation()
                return
            }

            var remainingPairs = sentencePairs
            let displayedPairs = sourceSegments.compactMap { segment in
                let key = Self.normalizedSourceKey(segment)
                if let exactIndex = remainingPairs.firstIndex(where: {
                    Self.normalizedSourceKey($0.original) == key
                }) {
                    return remainingPairs.remove(at: exactIndex)
                }
                if let revisedIndex = remainingPairs.firstIndex(where: {
                    Self.isLikelyRevision($0.original, replacement: segment)
                }) {
                    let previousPair = remainingPairs.remove(at: revisedIndex)
                    let previewPair = SentencePair(original: segment, translation: previousPair.translation)
                    // The old translation stays under the revised source until the new request lands.
                    RealtimeLog.log(
                        "align",
                        """
                        revised segment keeps old translation old=\(RealtimeLog.text(previousPair.original)) \
                        new=\(RealtimeLog.text(segment)) tr=\(RealtimeLog.text(previousPair.translation))
                        """
                    )
                    finalizedPreviewPairsBySource[key] = previewPair
                    return previewPair
                }
                return finalizedPreviewPairsBySource[key]
            }
            let droppedPairs = remainingPairs.filter {
                !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !droppedPairs.isEmpty {
                RealtimeLog.warn(
                    "align",
                    """
                    translated pairs dropped after source change dropped=\(RealtimeLog.segments(droppedPairs.map(\.original))) \
                    segs=\(RealtimeLog.segments(sourceSegments))
                    """
                )
            }
            assignDisplayedPairs(displayedPairs)
        }

        private mutating func assignDisplayedPairs(_ pairs: [SentencePair]) {
            sentencePairs = pairs
            translatedText = pairs.map(\.translation).joined(separator: "\n")
        }

        /// Resolves the pair to display for a source segment from the previously displayed pairs,
        /// falling back to the finalized preview translation. Consuming the matched entry keeps
        /// repeated identical segments aligned to distinct displayed pairs.
        private func displayedPair(
            forSegment segment: String,
            consuming existingPairsBySource: inout [String: [SentencePair]]
        ) -> SentencePair? {
            let key = Self.normalizedSourceKey(segment)
            if var existingPairs = existingPairsBySource[key], let pair = existingPairs.first {
                existingPairs.removeFirst()
                existingPairsBySource[key] = existingPairs
                return pair
            }
            return finalizedPreviewPairsBySource[key]
        }

        private mutating func pruneFinalizedPreviewPairs(to sourceSegments: [String]) {
            let sourceKeys = Set(sourceSegments.map(Self.normalizedSourceKey))
            finalizedPreviewPairsBySource = finalizedPreviewPairsBySource.filter { sourceKeys.contains($0.key) }
        }

        private mutating func cacheTranslatedSentencePair(_ pair: SentencePair, cacheKey: String) {
            let source = pair.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = pair.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty, !translation.isEmpty else { return }

            translatedPairsBySource[cacheKey] = SentencePair(original: source, translation: translation)
            translatedPairKeyOrder.removeAll { $0 == cacheKey }
            translatedPairKeyOrder.append(cacheKey)

            while translatedPairKeyOrder.count > Self.translatedPairCacheLimit {
                let removedKey = translatedPairKeyOrder.removeFirst()
                if !translatedPairKeyOrder.contains(removedKey) {
                    translatedPairsBySource.removeValue(forKey: removedKey)
                }
            }
        }

        private func cachedSentencePairs(
            from result: ModelExecutionResult,
            fallbackTranslation: String,
            request: RealtimeTextTranslationRequest
        ) -> [SentencePair] {
            let pairs = result.sentencePairs.filter {
                !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            if pairs.count == 1, let pair = pairs.first {
                return [
                    SentencePair(
                        original: request.translationText,
                        translation: pair.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                ]
            }

            if !pairs.isEmpty {
                return pairs
            }

            let translation = fallbackTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translation.isEmpty else { return [] }
            return [SentencePair(original: request.translationText, translation: translation)]
        }

        private func translatedText(
            from result: ModelExecutionResult,
            fallbackTranslation: String,
            request: RealtimeTextTranslationRequest
        ) -> String {
            cachedSentencePairs(from: result, fallbackTranslation: fallbackTranslation, request: request)
                .map(\.translation)
                .joined(separator: " ")
        }

        private func translationPairCacheKey(
            _ source: String,
            provider: RealtimeTranslationProvider?,
            sourceLanguage: SourceLanguageOption?,
            targetLanguage: TargetLanguageOption?
        ) -> String {
            [
                provider?.rawValue ?? "",
                sourceLanguage?.rawValue ?? "",
                targetLanguage?.rawValue ?? "",
                Self.normalizedSourceKey(source),
            ].joined(separator: "\t")
        }

        private static func transcriptSegments(from text: String) -> [String] {
            RealtimeTranscriptSegmenter.segments(from: text)
        }

        private static func sourceParts(committedText: String, pendingText: String) -> (stableText: String, pendingText: String) {
            let committed = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let pendingSplit = RealtimeTranscriptSegmenter.completedSegmentsAndPending(from: pendingText)
            let completedPending = pendingSplit.segments.joined(separator: "\n\n")
            let stableText = [committed, completedPending]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return (stableText, pendingSplit.pending)
        }

        private static func isLikelyRevision(_ previous: String, replacement: String) -> Bool {
            let previousKey = normalizedSourceKey(previous)
            let replacementKey = normalizedSourceKey(replacement)
            guard !previousKey.isEmpty, !replacementKey.isEmpty else { return false }
            if previousKey == replacementKey ||
                previousKey.hasPrefix(replacementKey) ||
                replacementKey.hasPrefix(previousKey)
            {
                return true
            }

            let previousTokens = Set(previousKey.split(separator: " "))
            let replacementTokens = Set(replacementKey.split(separator: " "))
            guard previousTokens.count >= 4, replacementTokens.count >= 4 else { return false }

            let sharedTokenCount = previousTokens.intersection(replacementTokens).count
            let shorterTokenCount = min(previousTokens.count, replacementTokens.count)
            return Double(sharedTokenCount) / Double(shorterTokenCount) >= 0.75
        }

        private mutating func updateSourceSegments(previousStableText: String) {
            guard translationSourceText != previousStableText else { return }

            if let incrementallyUpdatedSegments = Self.incrementallyUpdatedSegments(
                previousText: previousStableText,
                previousSegments: sourceSegments,
                currentText: translationSourceText
            ) {
                sourceSegments = incrementallyUpdatedSegments
                return
            }

            sourceSegments = Self.transcriptSegments(from: translationSourceText)
        }

        private static func incrementallyUpdatedSegments(
            previousText: String,
            previousSegments: [String],
            currentText: String
        ) -> [String]? {
            guard !previousText.isEmpty, currentText.hasPrefix(previousText) else { return nil }

            let suffix = String(currentText.dropFirst(previousText.count))
            guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return previousSegments
            }

            if suffix.hasPrefix("\n\n") || endsAtSentenceBoundary(previousText) {
                return previousSegments + transcriptSegments(from: suffix)
            }

            guard let previousTail = previousSegments.last else { return nil }
            let rebuiltTailSegments = transcriptSegments(from: previousTail + suffix)
            return Array(previousSegments.dropLast()) + rebuiltTailSegments
        }

        private static func endsAtSentenceBoundary(_ text: String) -> Bool {
            guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
            return [".", "!", "?", "。", "！", "？"].contains(last)
        }

        private static func finalizedPreviewPair(
            previousPendingSource: String,
            previousPendingTranslation: String,
            previousStableSegments: [String],
            currentStableSegments: [String]
        ) -> SentencePair? {
            guard !previousPendingSource.isEmpty,
                  !previousPendingTranslation.isEmpty,
                  !currentStableSegments.isEmpty
            else {
                return nil
            }

            let previousStableKeys = previousStableSegments.map(normalizedSourceKey)
            let currentStableKeys = currentStableSegments.map(normalizedSourceKey)
            let addedSegments: ArraySlice<String>
            if currentStableKeys.starts(with: previousStableKeys) {
                addedSegments = currentStableSegments.dropFirst(previousStableSegments.count)
            } else {
                let previousKeySet = Set(previousStableKeys)
                addedSegments = currentStableSegments[...].filter { !previousKeySet.contains(normalizedSourceKey($0)) }[...]
            }

            guard let finalizedSource = addedSegments.last(where: {
                isLikelyRevision(previousPendingSource, replacement: $0)
            }) else { return nil }
            return SentencePair(original: finalizedSource, translation: previousPendingTranslation)
        }

        private static func rollbackPreviewTranslation(
            previousStableSegments: [String],
            previousSentencePairs: [SentencePair],
            currentStableSegments: [String],
            currentPendingSource: String
        ) -> String? {
            let pending = currentPendingSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pending.isEmpty else { return nil }

            let currentKeys = Set(currentStableSegments.map(normalizedSourceKey))
            for segment in previousStableSegments.reversed() {
                guard !currentKeys.contains(normalizedSourceKey(segment)),
                      isLikelyRevision(segment, replacement: pending)
                else {
                    continue
                }
                guard let pair = previousSentencePairs.last(where: {
                    normalizedSourceKey($0.original) == normalizedSourceKey(segment)
                }) else {
                    continue
                }
                let translation = pair.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translation.isEmpty {
                    return translation
                }
            }
            return nil
        }

        /// Bounded memo: every recognition update re-keys the whole transcript, and folding is locale-bridged and slow.
        private static let normalizedSourceKeyCache = Mutex<[String: String]>([:])
        private static let normalizedSourceKeyCacheLimit = 4096

        private static func normalizedSourceKey(_ source: String) -> String {
            if let cached = normalizedSourceKeyCache.withLock({ $0[source] }) {
                return cached
            }
            let key = computeNormalizedSourceKey(source)
            normalizedSourceKeyCache.withLock { cache in
                if cache.count >= normalizedSourceKeyCacheLimit {
                    cache.removeAll(keepingCapacity: true)
                }
                cache[source] = key
            }
            return key
        }

        private static func computeNormalizedSourceKey(_ source: String) -> String {
            let folded = source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let normalized = folded.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
            }
            return String(normalized)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
    }
#endif
