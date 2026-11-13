#if os(iOS)
    import UIKit
#endif
import AVFoundation
import Combine
import CoreMedia
import Foundation
import os
import Translation

extension RealtimeSessionStore {
    nonisolated static func transcriptSegments(from text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func historySnapshot(
        sourceText: String,
        translatedText: String,
        pendingTranslatedText: String,
        checkpoint: inout RealtimeHistoryCheckpoint
    ) -> RealtimeHistorySnapshot? {
        let historyTranslatedText = joinedHistoryText(translatedText, pendingTranslatedText)
        return checkpoint.snapshot(sourceText: sourceText, translatedText: historyTranslatedText)
    }

    nonisolated static func historyPairs(
        sentencePairs: [SentencePair],
        pendingSourceText: String,
        pendingTranslatedText: String,
        sourceText: String,
        translatedText: String
    ) -> [SentencePair] {
        var pairs = sentencePairs
        let pendingSource = pendingSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingTranslation = pendingTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingSource.isEmpty, !pendingTranslation.isEmpty {
            pairs.append(SentencePair(original: pendingSource, translation: pendingTranslation))
        }

        if !pairs.isEmpty {
            return pairs
        }

        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty, !source.isEmpty else { return [] }
        return [SentencePair(original: source, translation: translation)]
    }

    nonisolated static func shouldAcceptRealtimeCallback(
        sessionID: UUID,
        activeSessionID: UUID,
        isStopping: Bool
    ) -> Bool {
        !isStopping && sessionID == activeSessionID
    }

    nonisolated static func shouldAcceptRealtimeCallbackDuringDrain(
        sessionID: UUID,
        activeSessionID: UUID,
        isStopping: Bool,
        drainingSessionID: UUID?
    ) -> Bool {
        sessionID == activeSessionID && (!isStopping || sessionID == drainingSessionID)
    }

    nonisolated static func joinedHistoryText(_ translatedText: String, _ pendingTranslatedText: String) -> String {
        let translated = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = pendingTranslatedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (translated.isEmpty, pending.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return pending
        case (false, true):
            return translated
        case (false, false):
            if translated == pending || translated.hasSuffix("\n\n\(pending)") {
                return translated
            }
            return "\(translated)\n\n\(pending)"
        }
    }
}

public extension RealtimeSessionStore {
    var captionTranslationAvailable: Bool {
        #if os(macOS)
            primaryLaneConfiguration?.translationProvider.performsTranslation
                ?? preferences.realtimeTranslationProvider.performsTranslation
        #else
            preferences.realtimeTranslationProvider.performsTranslation
        #endif
    }

    /// The mode `captionLines` were built for; transcription-only sessions always show source captions.
    var resolvedCaptionDisplayMode: RealtimeCaptionDisplayMode {
        if !captionTranslationAvailable {
            return .sourceOnly
        }
        return captionDisplayMode
    }
}

extension RealtimeSessionStore {
    func logRealtime(_ message: String, stage: String = "session") {
        RealtimeLog.log(stage, message)
    }

    func assignIfChanged<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
        if value != newValue {
            value = newValue
        }
    }

    func refreshCaptionLines(event: String) {
        let allLines = resolvedCaptionLines()
        let visibleLines = RealtimeCaptionDisplay.linesVisibleAfterClear(allLines, anchor: captionClearAnchor)
        #if os(macOS)
            let displayLines = RealtimeCaptionDisplay.displayWindow(visibleLines, limit: Self.captionLineDisplayLimit)
        #else
            let displayLines = visibleLines
        #endif
        if captionLines != displayLines {
            #if DEBUG
                // Re-segments the whole transcript; too costly for every release partial.
                logCaptionDiagnostics(event: event, allLines: allLines, displayLines: displayLines)
            #endif
            logCaptionLayoutChange(event: event, from: captionLines, to: displayLines)
            logCaptionRevision(event: event, from: captionLines, to: displayLines)
        }
        assignIfChanged(&captionLines, displayLines)
    }

    /// Starts one traced input (ASR result or translation reply); every caption revision it
    /// produces logs `cause=<kind>#<n>`, so a jump can be followed from input to layout.
    func beginCaptionTrace(_ kind: String, _ detail: String) {
        captionTraceSequence += 1
        captionUpdateCause = "\(kind)#\(captionTraceSequence)"
        RealtimeLog.log("trace", "\(captionUpdateCause) \(detail) rev=\(captionRevision)")
    }

    /// Logs every published caption change with the lines that changed, unfiltered.
    func logCaptionRevision(
        event: String,
        from oldLines: [RealtimeCaptionLine],
        to newLines: [RealtimeCaptionLine]
    ) {
        captionRevision += 1
        let now = ContinuousClock.now
        let gap = lastCaptionRevisionTime.map { "\(Int(($0.duration(to: now) / .milliseconds(1)).rounded()))ms" } ?? "-"
        lastCaptionRevisionTime = now

        let common = min(oldLines.count, newLines.count)
        let firstChanged = (0 ..< common).first { oldLines[$0] != newLines[$0] } ?? common
        let oldByID = Dictionary(oldLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changes = newLines.dropFirst(firstChanged).prefix(6).map { line -> String in
            let flag = line.isPending ? "*" : ""
            guard let old = oldByID[line.id] else {
                return "+\(line.id)\(flag)=\(RealtimeLog.text(line.text, limit: 40))"
            }
            if old == line {
                return "=\(line.id)"
            }
            let pending = old.isPending == line.isPending ? "" : " pending:\(old.isPending)->\(line.isPending)"
            return "~\(line.id)\(flag)\(pending) \(RealtimeLog.text(old.text, limit: 40))->\(RealtimeLog.text(line.text, limit: 40))"
        }
        let newIDs = Set(newLines.map(\.id))
        let removed = oldLines.dropFirst(firstChanged).filter { !newIDs.contains($0.id) }.map { "-\($0.id)" }
        RealtimeLog.log(
            "ui",
            """
            rev=\(captionRevision) cause=\(captionUpdateCause) event=\(event) gap=\(gap) \
            lines=\(oldLines.count)->\(newLines.count) from=\(firstChanged) \
            \((changes + removed).joined(separator: " | "))
            """
        )
    }

    /// Logs caption changes likely to shift layout height: line identity churn or a large
    /// per-line text delta. Small in-place growth of a line is skipped to keep the log readable.
    func logCaptionLayoutChange(
        event: String,
        from oldLines: [RealtimeCaptionLine],
        to newLines: [RealtimeCaptionLine]
    ) {
        let oldByID = Dictionary(oldLines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(newLines.map(\.id))
        let added = newLines.filter { oldByID[$0.id] == nil }.map(\.id)
        let removed = oldLines.filter { !newIDs.contains($0.id) }.map(\.id)
        let resized = newLines.compactMap { line -> String? in
            guard let old = oldByID[line.id] else { return nil }
            let delta = line.text.count - old.text.count
            return abs(delta) >= 12 ? "\(line.id):\(old.text.count)->\(line.text.count)" : nil
        }
        guard !added.isEmpty || !removed.isEmpty || !resized.isEmpty else { return }

        let oldChars = oldLines.reduce(0) { $0 + $1.text.count }
        let newChars = newLines.reduce(0) { $0 + $1.text.count }
        let layout = newLines.map { "\($0.id)\($0.isPending ? "*" : ""):\($0.text.count)" }
        RealtimeLog.log(
            "layout",
            """
            event=\(event) lines=\(oldLines.count)->\(newLines.count) chars=\(oldChars)->\(newChars) \
            added=\(added) removed=\(removed) resized=\(resized) \
            tail=\(layout.suffix(6)) pendingSrc=\(RealtimeLog.text(pendingSourceText, limit: 24)) \
            pendingTr=\(RealtimeLog.text(pendingTranslatedText, limit: 24))
            """
        )
    }

    /// Flags caption states that look like misalignment or missing text. Deduplicated by
    /// signature so an unchanged problem is logged once, not on every recognition tick.
    func logCaptionDiagnostics(
        event: String,
        allLines: [RealtimeCaptionLine],
        displayLines: [RealtimeCaptionLine]
    ) {
        let segments = presentationSourceSegments
        let segmentKeys = Set(segments.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
        // Translations appended at the bottom because their source line could not be matched.
        let orphanTranslations = displayLines.filter { $0.id.hasPrefix("previous-translation") }
        // Pairs whose original no longer equals any current segment (whitespace-normalized).
        let unmatchedPairs = sentencePairs.filter {
            !segmentKeys.contains($0.original.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let inFlight = displayLines.filter { $0.id.hasSuffix("-source-in-flight") }
        let hasTranslationWork = translationScheduler.finalTask != nil || !translationScheduler.queuedFinal.isEmpty
        let stuckUntranslated = hasTranslationWork ? [] : inFlight
        let hiddenByClear = allLines.count - displayLines.count
        let duplicateIDs = Dictionary(grouping: displayLines, by: \.id).filter { $0.value.count > 1 }.keys
        let lostAllLines = displayLines.isEmpty && !captionLines.isEmpty && !sourceText.isEmpty

        var problems: [String] = []
        if !orphanTranslations.isEmpty {
            problems.append("orphanTranslations=\(RealtimeLog.segments(orphanTranslations.map(\.text)))")
        }
        if !unmatchedPairs.isEmpty {
            problems.append("unmatchedPairs=\(RealtimeLog.segments(unmatchedPairs.map(\.original)))")
        }
        if !stuckUntranslated.isEmpty {
            problems.append("untranslatedIdle=\(RealtimeLog.segments(stuckUntranslated.map(\.text)))")
        }
        if !duplicateIDs.isEmpty {
            problems.append("duplicateIDs=\(duplicateIDs.sorted())")
        }
        if lostAllLines {
            problems.append("allLinesDisappeared sourceLen=\(sourceText.count)")
        }
        if displayLines.count < captionLines.count, !sourceText.isEmpty {
            let currentIDs = Set(displayLines.map(\.id))
            let removed = captionLines.filter { !currentIDs.contains($0.id) }.prefix(4)
            problems.append(
                "lines=\(captionLines.count)->\(displayLines.count) removed=\(removed.map { "\($0.id):\(RealtimeLog.text($0.text, limit: 24))" })"
            )
        }

        guard !problems.isEmpty else {
            lastCaptionDiagnosticsSignature = nil
            return
        }
        let signature = problems.joined(separator: " ")
        guard signature != lastCaptionDiagnosticsSignature else { return }
        lastCaptionDiagnosticsSignature = signature
        RealtimeLog.warn(
            "caption",
            """
            event=\(event) mode=\(resolvedCaptionDisplayMode.rawValue) segs=\(segments.count) \
            pairs=\(sentencePairs.count) hiddenByClear=\(hiddenByClear) \(signature) \
            tail=\(RealtimeLog.segments(segments, tail: 2))
            """
        )
    }

    static func logSourceSegmentChange(
        from previous: [String],
        to current: [String],
        pending: String,
        result: RealtimeRecognitionResult
    ) {
        guard previous != current else { return }
        let offset = result.audioOffset.map { String(format: "%.1fs", $0) } ?? "-"
        if current.starts(with: previous) {
            RealtimeLog.log(
                "src",
                """
                commit +\(current.count - previous.count) segs=\(current.count) at=\(offset) \
                new=\(RealtimeLog.segments(Array(current.dropFirst(previous.count)), tail: 4)) \
                pending=\(RealtimeLog.text(pending))
                """
            )
            return
        }
        let firstChanged = zip(previous, current).prefix { $0 == $1 }.count
        let old = previous.dropFirst(firstChanged).prefix(3).map { RealtimeLog.text($0, limit: 32) }
        let new = current.dropFirst(firstChanged).prefix(3).map { RealtimeLog.text($0, limit: 32) }
        // Revisions of already-committed text are the main source of source/translation drift.
        RealtimeLog.warn(
            "src",
            """
            revised segs=\(previous.count)->\(current.count) from=[\(firstChanged)] at=\(offset) \
            final=\(result.state == .final) old=\(old.joined(separator: " ")) new=\(new.joined(separator: " "))
            """
        )
    }

    func resolvedCaptionLines() -> [RealtimeCaptionLine] {
        RealtimeCaptionDisplay.resolvedLines(
            pairs: sentencePairs,
            translatedSourceSegments: presentationSourceSegments,
            translatedSource: translationSourceText,
            translatedText: translatedText,
            pendingSource: pendingSourceText,
            pendingTranslation: pendingTranslatedText,
            sourceText: sourceText,
            mode: resolvedCaptionDisplayMode,
            showsUntranslatedSource: true
        )
    }

    #if os(iOS)
        func logBroadcastStateIfNeeded(_ state: RealtimeBroadcastState) {
            let signature = [
                state.sessionID,
                state.phase.rawValue,
                "\(state.sourceText.count)",
                "\(state.translationSourceText.count)",
                "\(state.pendingSourceText.count)",
                "\(state.translatedText.count)",
                "\(state.pendingTranslatedText.count)",
                "\(state.sentencePairs.count)",
                state.errorMessage ?? "",
            ].joined(separator: "|")
            guard signature != lastBroadcastStateLogSignature else { return }
            lastBroadcastStateLogSignature = signature
            logRealtime(
                """
                state session=\(state.sessionID) phase=\(state.phase.rawValue) \
                sourceLen=\(state.sourceText.count) stableLen=\(state.translationSourceText.count) \
                pendingLen=\(state.pendingSourceText.count) translatedLen=\(state.translatedText.count) \
                pendingTranslationLen=\(state.pendingTranslatedText.count) pairs=\(state.sentencePairs.count) \
                audioSamples=\(state.audioSampleCount) error=\(state.errorMessage ?? "")
                """,
                stage: "broadcast"
            )
        }
    #endif

    static func translationErrorMessage(
        _ error: Error,
        source: Locale.Language?,
        target: TargetLanguageOption,
        provider: RealtimeTranslationProvider
    ) -> String {
        switch provider {
        case .appleTranslator, .appleTranslationRealtime:
            return AppleTranslationErrorFormatter.describe(error, source: source, target: target)
        case .transcriptionOnly:
            return describe(error)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "kLSRErrorDomain", nsError.code == 300 {
            return appendNSErrorDetails(to: """
            Apple Speech failed to initialize the recognizer. \
            Restart the device or change the source language.
            """, nsError: nsError)
        }
        if nsError.domain == "SFSpeechErrorDomain", nsError.code == 4 {
            return appendNSErrorDetails(
                to: "Apple Speech could not load the recognition model for the selected source language.",
                nsError: nsError
            )
        }
        let baseMessage: String
        if let localized = error as? LocalizedError {
            let description = localized.errorDescription ?? ""
            if !description.isEmpty {
                baseMessage = description
            } else {
                baseMessage = error.localizedDescription
            }
        } else {
            baseMessage = error.localizedDescription
        }

        guard !(error is LocalizedError) else { return baseMessage }
        return appendNSErrorDetails(to: baseMessage, nsError: nsError)
    }

    nonisolated static func appendNSErrorDetails(to message: String, nsError: NSError) -> String {
        var details: [String] = []
        if !nsError.domain.isEmpty, !message.contains(nsError.domain) {
            details.append("Error: \(nsError.domain) \(nsError.code)")
        }
        if let reason = nsError.localizedFailureReason, !reason.isEmpty, !message.contains(reason) {
            details.append("Reason: \(reason)")
        }
        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty, !message.contains(suggestion) {
            details.append("Suggestion: \(suggestion)")
        }
        guard !details.isEmpty else { return message }
        return ([message] + details).joined(separator: "\n\n")
    }

    func shouldAcceptRealtimeCallback(sessionID: UUID) -> Bool {
        Self.shouldAcceptRealtimeCallbackDuringDrain(
            sessionID: sessionID,
            activeSessionID: activeSessionID,
            isStopping: isStopping,
            drainingSessionID: drainingSessionID
        )
    }

    func updateTranscriptPresentation() {
        translationState.updateSources(from: transcriptAccumulator)
        syncTranslationStatePresentation()
    }

    func enqueueFinalTranslationRequests(
        provider: RealtimeTranslationProvider,
        sourceLanguage: SourceLanguageOption,
        source: Locale.Language?,
        targetLanguage: TargetLanguageOption
    ) {
        let requests = translationState.makeFinalTranslationRequests(
            provider: provider,
            sourceLanguage: sourceLanguage,
            source: source,
            targetLanguage: targetLanguage
        )
        guard !requests.isEmpty else { return }
        translationScheduler.enqueueFinal(requests)

        RealtimeLog.log(
            "tx",
            """
            enqueue final +\(requests.count) queued=\(translationScheduler.queuedFinal.count) \
            segs=\(translationState.sourceSegments.count) src=\(RealtimeLog.segments(requests.map(\.translationText)))
            """
        )
    }

    func schedulePartialTranslation(
        provider: RealtimeTranslationProvider,
        sourceLanguage: SourceLanguageOption,
        source: Locale.Language?,
        targetLanguage: TargetLanguageOption
    ) {
        guard let request = translationState.makePartialTranslationRequest(
            provider: provider,
            sourceLanguage: sourceLanguage,
            source: source,
            targetLanguage: targetLanguage
        ) else {
            if translationState.pendingSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cancelPartialTranslationWork()
                syncTranslationStatePresentation()
            }
            return
        }

        translationScheduler.submitPartial(request)
    }

    func applyFinalTranslationResult(
        _ result: ModelExecutionResult,
        request: RealtimeTextTranslationRequest
    ) {
        beginCaptionTrace("txf", "src=\(RealtimeLog.text(request.translationText))")
        defer { captionUpdateCause = "-" }
        guard requestMatchesCurrentConfiguration(request) else {
            RealtimeLog.warn(
                "tx",
                "final discarded reason=configChanged src=\(RealtimeLog.text(request.translationText))"
            )
            translationState.finishFinalTranslationRequest(request)
            syncTranslationStatePresentation()
            return
        }

        switch result.response {
        case let .success(text):
            let applied = translationState.applyFinalTranslationSuccess(result, request: request)
            let segmentCount = translationState.sourceSegments.count
            let pairCount = translationState.sentencePairs.count
            let isStillDisplayed = translationState.sentencePairs.contains { $0.original == request.translationText }
            RealtimeLog.log(
                "tx",
                """
                final ok \(Int(result.duration * 1000))ms src=\(RealtimeLog.text(request.translationText)) \
                -> tr=\(RealtimeLog.text(text)) modelPairs=\(result.sentencePairs.count) applied=\(applied) \
                displayed=\(isStillDisplayed) pairs=\(pairCount)/\(segmentCount)
                """
            )
            if !isStillDisplayed {
                // The segment was revised while its translation was in flight; the caption keeps
                // the new text untranslated until the next request finishes.
                RealtimeLog.warn(
                    "align",
                    """
                    final result has no matching segment src=\(RealtimeLog.text(request.translationText)) \
                    segs=\(RealtimeLog.segments(translationState.sourceSegments))
                    """
                )
            }
            syncTranslationStatePresentation()
        case let .failure(error):
            let message = Self.translationErrorMessage(
                error,
                source: request.source,
                target: request.targetLanguage,
                provider: request.provider
            )
            RealtimeLog.warn("tx", "final failure src=\(RealtimeLog.text(request.translationText)) error=\(message)")
            translationState.finishFinalTranslationRequest(request)
            syncTranslationStatePresentation()
            handleErrorMessage(message)
        }
    }

    func applyPartialTranslationResult(
        _ result: ModelExecutionResult,
        request: RealtimeTextTranslationRequest
    ) {
        beginCaptionTrace("txp", "src=\(RealtimeLog.text(request.translationText))")
        defer { captionUpdateCause = "-" }
        guard requestMatchesCurrentConfiguration(request) else {
            RealtimeLog.warn(
                "tx",
                "partial discarded reason=configChanged src=\(RealtimeLog.text(request.translationText))"
            )
            return
        }

        switch result.response {
        case let .success(text):
            if translationState.applyPartialTranslationSuccess(result, request: request) {
                RealtimeLog.log(
                    "tx",
                    """
                    partial ok \(Int(result.duration * 1000))ms src=\(RealtimeLog.text(request.translationText)) \
                    -> tr=\(RealtimeLog.text(text))
                    """
                )
                syncTranslationStatePresentation()
                updateStatusAfterTranslationActivity()
            } else {
                RealtimeLog.log(
                    "tx",
                    """
                    partial stale \(Int(result.duration * 1000))ms src=\(RealtimeLog.text(request.translationText)) \
                    pendingNow=\(RealtimeLog.text(translationState.pendingSourceText))
                    """
                )
            }
        case let .failure(error):
            let message = Self.translationErrorMessage(
                error,
                source: request.source,
                target: request.targetLanguage,
                provider: request.provider
            )
            RealtimeLog.warn("tx", "partial failure src=\(RealtimeLog.text(request.translationText)) error=\(message)")
            handleErrorMessage(message)
        }
    }

    func syncTranslationStatePresentation() {
        assignIfChanged(&translationSourceText, translationState.translationSourceText)
        assignIfChanged(&pendingSourceText, translationState.pendingSourceText)
        assignIfChanged(&translatedText, translationState.translatedText)
        assignIfChanged(&sentencePairs, translationState.sentencePairs)
        assignIfChanged(&pendingTranslatedText, translationState.pendingTranslatedText)
        presentationSourceSegments = translationState.sourceSegments
        autosaveRealtimeHistoryIfNeeded()
        refreshCaptionLines(event: "syncTranslationStatePresentation")
    }

    func requestMatchesCurrentConfiguration(_ request: RealtimeTextTranslationRequest) -> Bool {
        request.provider == preferences.realtimeTranslationProvider &&
            request.sourceLanguage == preferences.realtimeSourceLanguage &&
            request.targetLanguage == preferences.realtimeTargetLanguage
    }

    func updateStatusAfterTranslationActivity() {
        let hasTranslationWork = translationScheduler.hasWork
        statusText = hasTranslationWork
            ? String(localized: "Translating")
            :
            (
                isRunning ?
                    (isPaused ? String(localized: "Paused") : String(localized: "Listening to \(inputSource.title)")) :
                    String(localized: "Stopped")
            )
    }

    func cancelTranslationWork() {
        if translationScheduler.hasWork {
            RealtimeLog.log(
                "tx",
                """
                cancel finalTask=\(translationScheduler.finalTask != nil) \
                partialTask=\(translationScheduler.partialTask != nil) \
                queuedFinal=\(translationScheduler.queuedFinal.count) \
                latestPartial=\(translationScheduler.latestPartial != nil)
                """
            )
        }
        translationScheduler.cancelAll()
        translationState.cancelQueuedFinalTranslationRequests()
    }

    func cancelPartialTranslationWork() {
        translationScheduler.cancelPartial()
    }
}

extension RealtimeSessionStore: RealtimeLiveSpeechTranscriberDelegate {
    nonisolated func realtimeLiveSpeechTranscriber(
        _: RealtimeLiveSpeechTranscriber,
        sessionID: UUID,
        didRecognize result: RealtimeRecognitionResult
    ) {
        let callbackDrain = callbackDrain
        callbackDrain.enter()
        Task { @MainActor [weak self] in
            defer { callbackDrain.leave() }
            guard let self, shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
            handleRecognized(result)
        }
    }

    nonisolated func realtimeLiveSpeechTranscriber(
        _: RealtimeLiveSpeechTranscriber,
        sessionID: UUID,
        didFail error: Error
    ) {
        let callbackDrain = callbackDrain
        callbackDrain.untrackedMainActorTask { [weak self] in
            guard let self, shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
            await handleRuntimeFailure(error, context: "speech")
        }
    }
}

#if arch(arm64) && canImport(FluidAudio)
    extension RealtimeSessionStore: RealtimeFluidAudioRecognizerDelegate {
        nonisolated func realtimeFluidAudioRecognizer(
            _: RealtimeFluidAudioRecognizer,
            sessionID: UUID,
            didRecognize result: RealtimeRecognitionResult
        ) {
            let callbackDrain = callbackDrain
            callbackDrain.enter()
            Task { @MainActor [weak self] in
                defer { callbackDrain.leave() }
                guard let self, shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
                handleRecognized(result)
            }
        }

        nonisolated func realtimeFluidAudioRecognizer(
            _: RealtimeFluidAudioRecognizer,
            sessionID: UUID,
            didFail error: Error
        ) {
            let callbackDrain = callbackDrain
            callbackDrain.untrackedMainActorTask { [weak self] in
                guard let self, shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
                await handleRuntimeFailure(error, context: "fluidAudio")
            }
        }
    }
#endif

#if os(macOS)
    extension RealtimeSessionStore: RealtimeSystemAudioCaptureDelegate {
        nonisolated func realtimeSystemAudioCapture(
            _ capture: RealtimeSystemAudioCapture,
            didOutput sampleBuffer: CMSampleBuffer
        ) {
            if capture === secondarySystemAudioCapture {
                let completedAudioSegment = secondaryAudioHistoryRecorder.append(sampleBuffer)
                if completedAudioSegment {
                    Task { @MainActor [weak self] in
                        self?.autosaveRealtimeHistoryIfNeeded()
                    }
                }
                return
            }

            realtimePipelineAudioFanout.append(sampleBuffer)
            let completedAudioSegment = audioHistoryRecorder.append(sampleBuffer)
            if completedAudioSegment {
                Task { @MainActor [weak self] in
                    self?.autosaveRealtimeHistoryIfNeeded()
                }
            }
        }

        nonisolated func realtimeSystemAudioCapture(
            _ capture: RealtimeSystemAudioCapture,
            didReceiveAudioSampleCount count: Int,
            level: Float?
        ) {
            guard capture === systemAudioCapture else { return }
            Task { @MainActor [weak self] in
                self?.updateAudioSampleCount(count, level: level)
            }
        }

        nonisolated func realtimeSystemAudioCapture(_ capture: RealtimeSystemAudioCapture, didFail error: Error) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if capture === self.secondarySystemAudioCapture {
                    await self.handleSecondaryAudioFailure(error, source: .macAudio)
                } else {
                    await self.handleRuntimeFailure(error, context: "systemAudio")
                }
            }
        }
    }
#endif

extension RealtimeSessionStore: RealtimeMicrophoneAudioCaptureDelegate {
    nonisolated func realtimeMicrophoneAudioCapture(
        _ capture: RealtimeMicrophoneAudioCapture,
        didOutput sampleBuffer: CMSampleBuffer
    ) {
        #if os(macOS)
            if capture === secondaryMicrophoneAudioCapture {
                let completedAudioSegment = secondaryAudioHistoryRecorder.append(sampleBuffer)
                if completedAudioSegment {
                    Task { @MainActor [weak self] in
                        self?.autosaveRealtimeHistoryIfNeeded()
                    }
                }
                return
            }
        #endif

        #if os(macOS)
            realtimePipelineAudioFanout.append(sampleBuffer)
        #else
            activeRecognizer.append(sampleBuffer)
        #endif
        let completedAudioSegment = audioHistoryRecorder.append(sampleBuffer)
        if completedAudioSegment {
            Task { @MainActor [weak self] in
                self?.autosaveRealtimeHistoryIfNeeded()
            }
        }
    }

    nonisolated func realtimeMicrophoneAudioCapture(
        _ capture: RealtimeMicrophoneAudioCapture,
        didOutput pcmBuffer: AVAudioPCMBuffer
    ) {
        #if os(macOS)
            if capture === secondaryMicrophoneAudioCapture {
                let completedAudioSegment = secondaryAudioHistoryRecorder.append(pcmBuffer)
                if completedAudioSegment {
                    Task { @MainActor [weak self] in
                        self?.autosaveRealtimeHistoryIfNeeded()
                    }
                }
                return
            }
        #endif

        // Recognition first; the capture tap delivers a fresh buffer, so AAC encoding can
        // run on the recorder's queue instead of the realtime audio thread.
        #if os(macOS)
            realtimePipelineAudioFanout.append(pcmBuffer)
        #else
            activeRecognizer.append(pcmBuffer)
        #endif
        audioHistoryRecorder.enqueue(pcmBuffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.autosaveRealtimeHistoryIfNeeded()
            }
        }
    }

    nonisolated func realtimeMicrophoneAudioCapture(
        _ capture: RealtimeMicrophoneAudioCapture,
        didReceiveAudioSampleCount count: Int,
        level: Float?
    ) {
        #if os(macOS)
            guard capture === microphoneAudioCapture else { return }
        #endif
        Task { @MainActor [weak self] in
            self?.updateAudioSampleCount(count, level: level)
        }
    }

    nonisolated func realtimeMicrophoneAudioCapture(_ capture: RealtimeMicrophoneAudioCapture, didFail error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if os(macOS)
                if capture === self.secondaryMicrophoneAudioCapture {
                    await self.handleSecondaryAudioFailure(error, source: .microphone)
                    return
                }
            #endif
            await self.handleRuntimeFailure(error, context: "microphone")
        }
    }
}
