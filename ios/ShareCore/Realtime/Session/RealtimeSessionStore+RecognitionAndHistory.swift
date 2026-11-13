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
    public func languageSelectionDidChange() {
        logRealtime(
            """
            languageSelectionDidChange provider=\(preferences.realtimeTranslationProvider.rawValue) \
            source=\(preferences.realtimeSourceLanguage.rawValue) target=\(preferences.realtimeTargetLanguage.rawValue)
            """
        )
        cancelTranslationWork()
        errorMessage = nil
        translationState.resetTranslationResults()
        updateTranscriptPresentation()
        scheduleTranslation()
    }

    func speechLocale() -> Locale {
        switch preferences.realtimeSourceLanguage {
        case .auto:
            return RecognitionModelStore.selectableDescriptor(
                forModelID: preferences.realtimeRecognitionModelID
            ) == .nemotronMultilingual2240
                ? Locale(identifier: "und")
                : Locale(identifier: "en-US")
        default:
            return Locale(identifier: preferences.realtimeSourceLanguage.rawValue)
        }
    }

    #if os(iOS)
        func registerSessionLifecycle() {
            // Recording continues while the device is locked: History and audio files use the
            // default protection class, which stays readable after the first unlock.
            sessionLifecycleObservers = [
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
                    else {
                        return
                    }
                    let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                    Task { @MainActor in
                        self?.handleAudioSessionInterruption(type, shouldResume: shouldResume)
                    }
                },
            ]
        }

        /// A call, Siri or alarm pauses a long session instead of ending it, and resumes it when
        /// the system says so. Without that hint it stays paused until the user resumes.
        func handleAudioSessionInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
            guard isRunning, inputSource == .microphone else { return }
            switch type {
            case .began:
                guard !isPaused else { return }
                pause()
                isPausedForAudioInterruption = true
                logRealtime("audio interruption began; paused")
            case .ended:
                guard isPausedForAudioInterruption, isPaused else { return }
                isPausedForAudioInterruption = false
                logRealtime("audio interruption ended shouldResume=\(shouldResume)")
                if shouldResume {
                    togglePaused()
                }
            @unknown default:
                break
            }
        }

        func startIPhoneAudioBroadcastSession() async {
            logRealtime(
                """
                start requested source=\(preferences.realtimeSourceLanguage.rawValue) \
                target=\(preferences.realtimeTargetLanguage.rawValue)
                """,
                stage: "broadcast"
            )
            // Runs first so a missing language pack surfaces as the alert that offers the download.
            do {
                try await ensureAppleTranslateLanguagesInstalledIfNeeded()
            } catch {
                logRealtime("languagePreflightFailed error=\(Self.describe(error))", stage: "broadcast")
                handleStartFailure(error)
                return
            }
            if let failure = await RealtimeIPhoneAudioPreflight.evaluate(
                sourceLanguage: preferences.realtimeSourceLanguage,
                targetLanguage: preferences.realtimeTargetLanguage,
                requiresTranslation: preferences.realtimeTranslationProvider.performsTranslation
            ) {
                logRealtime("preflightFailed error=\(Self.describe(failure))", stage: "broadcast")
                handleStartFailure(failure)
                return
            }

            resetTranscript()
            isPaused = false
            errorMessage = nil
            startFailureAlert = nil
            audioLevel = nil
            audioSampleCount = 0
            isIPhoneAudioCaptureReady = false

            let sessionID = UUID().uuidString
            broadcastStateStore?.reset(sessionID: sessionID, phase: .waiting)
            RealtimeAudioRelay.removeStaleSessions(keeping: nil)
            usesHostRecognitionRelay = false
            if let relayModel = await hostRelayRecognitionModel() {
                let recognitionSessionID = activeSessionID
                logRealtime("host recognition loading model=\(relayModel.id) session=\(sessionID)", stage: "relay")
                do {
                    _ = try await startRecognition(sessionID: recognitionSessionID)
                } catch {
                    logRealtime("host recognition load failed error=\(Self.describe(error))", stage: "relay")
                    handleStartFailure(error)
                    return
                }
                guard shouldAcceptRealtimeCallback(sessionID: recognitionSessionID) else {
                    logRealtime("host recognition abandoned reason=sessionChanged", stage: "relay")
                    await activeRecognizer.stop()
                    return
                }
                if let reader = RealtimeAudioRelayReader(sessionID: sessionID) {
                    usesHostRecognitionRelay = true
                    broadcastStateStore?.update(sessionID: sessionID, synchronize: true) { state in
                        state.usesHostRecognition = true
                    }
                    broadcastStateStore?.markHostAlive(sessionID: sessionID)
                    startRealtimeHistorySessionIfNeeded()
                    startHostRecognitionRelay(reader: reader)
                    logRealtime("host recognition ready model=\(relayModel.id) session=\(sessionID)", stage: "relay")
                } else {
                    logRealtime("host recognition unavailable reason=noRelayReader; extension recognizes", stage: "relay")
                    await activeRecognizer.stop()
                }
            } else {
                logRealtime("host recognition off model=\(preferences.realtimeRecognitionModelID)", stage: "relay")
            }
            isRunning = true
            statusText = String(localized: "Waiting for iPhone Audio broadcast")
            lastBroadcastStateLogSignature = nil
            lastAppliedBroadcastSourceSegments = []
            logRealtime("waiting session=\(sessionID)", stage: "broadcast")
            startBroadcastStatePolling(sessionID: sessionID)
        }

        func startBroadcastStatePolling(sessionID: String) {
            stopBroadcastStatePolling()
            broadcastStatePollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.pollBroadcastState(sessionID: sessionID)
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }
                }
            }
        }

        func stopBroadcastStatePolling() {
            broadcastStatePollingTask?.cancel()
            broadcastStatePollingTask = nil
        }

        func waitForIPhoneAudioBroadcastStop(sessionID: String?) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while isRunning, inputSource == .iphoneAudio, ContinuousClock.now < deadline {
                if let state = broadcastStateStore?.load(), state.sessionID == sessionID {
                    switch state.phase {
                    case .stopped, .failed:
                        applyBroadcastState(state)
                        return
                    default:
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        func pollBroadcastState(sessionID: String) {
            guard isRunning, inputSource == .iphoneAudio else {
                stopBroadcastStatePolling()
                return
            }
            guard !isDrainingHostRecognitionRelay else { return }
            if usesHostRecognitionRelay {
                broadcastStateStore?.markHostAlive(sessionID: sessionID)
            }

            guard let state = broadcastStateStore?.load(),
                  state.sessionID == sessionID
            else {
                statusText = String(localized: "Waiting for iPhone Audio broadcast")
                return
            }
            if Self.isIPhoneAudioBroadcastWaitTimedOut(state) {
                broadcastStateStore?.update(synchronize: true) { state in
                    guard state.sessionID == sessionID,
                          Self.isIPhoneAudioBroadcastWaitTimedOut(state)
                    else {
                        return
                    }
                    state.phase = .stopped
                    state.stopRequested = false
                }
                if let state = broadcastStateStore?.load(),
                   state.sessionID == sessionID,
                   state.phase == .stopped
                {
                    endIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                }
                return
            }

            applyBroadcastState(state)
        }

        func applyBroadcastState(_ state: RealtimeBroadcastState) {
            if usesHostRecognitionRelay, !state.usesHostRecognition, hostRecognitionRelayTask != nil {
                handOffHostRecognitionToExtension(state: state)
                return
            }
            // Polling mostly delivers heartbeats; skip transcript work and
            // `@Published` writes when the text did not move. Relayed sessions keep the host transcript.
            let transcriptChanged = !usesHostRecognitionRelay && (
                sourceText != state.sourceText
                    || translationSourceText != state.translationSourceText
                    || pendingSourceText != state.pendingSourceText
                    || translatedText != state.translatedText
                    || pendingTranslatedText != state.pendingTranslatedText
                    || sentencePairs != state.sentencePairs
                    || lastAppliedBroadcastSourceSegments != state.sourceSegments
            )
            if !usesHostRecognitionRelay {
                assignIfChanged(&sourceText, state.sourceText)
            }
            if transcriptChanged {
                lastAppliedBroadcastSourceSegments = state.sourceSegments
                assignIfChanged(&translationSourceText, state.translationSourceText)
                assignIfChanged(
                    &presentationSourceSegments,
                    state.sourceSegments.isEmpty
                        ? RealtimeTranscriptSegmenter.segments(from: state.translationSourceText)
                        : state.sourceSegments
                )
                assignIfChanged(&pendingSourceText, state.pendingSourceText)
                assignIfChanged(&translatedText, state.translatedText)
                assignIfChanged(&pendingTranslatedText, state.pendingTranslatedText)
                assignIfChanged(&sentencePairs, state.sentencePairs)
            }
            assignIfChanged(&audioSampleCount, state.audioSampleCount)
            assignIfChanged(&audioLevel, state.audioLevel)
            assignIfChanged(&errorMessage, state.errorMessage)
            assignIfChanged(&isIPhoneAudioCaptureReady, state.isRecognitionReady)
            if !usesHostRecognitionRelay {
                latestBroadcastRealtimeHistorySession = state.realtimeHistorySession
            }
            autosaveRealtimeHistoryIfNeeded()
            if transcriptChanged {
                refreshCaptionLines(event: "broadcastState")
            }
            logBroadcastStateIfNeeded(state)

            if state.isStale(), state.phase != .stopped, state.phase != .failed {
                if Self.isStaleActiveIPhoneAudioBroadcast(state) {
                    let alert = Self.iPhoneAudioBroadcastFailureAlert(for: state)
                    endIPhoneAudioBroadcastSession(status: String(localized: "Error"), alert: alert)
                } else {
                    statusText = String(localized: "Waiting for iPhone Audio broadcast")
                }
                return
            }

            switch state.phase {
            case .idle, .waiting:
                statusText = String(localized: "Waiting for iPhone Audio broadcast")
            case .broadcasting:
                statusText = state.audioSampleCount == 0
                    ? String(localized: "Broadcasting, no app audio detected")
                    : String(localized: "Broadcasting iPhone Audio")
            case .recognizing:
                statusText = String(localized: "Recognizing iPhone Audio")
            case .translating:
                statusText = String(localized: "Translating")
            case .paused:
                statusText = String(localized: "iPhone Audio broadcast paused")
            case .stopping:
                statusText = String(localized: "Stopping iPhone Audio")
            case .stopped:
                endIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
            case .failed:
                let alert = Self.iPhoneAudioBroadcastFailureAlert(for: state)
                endIPhoneAudioBroadcastSession(status: String(localized: "Error"), alert: alert)
            }
        }

        func hostRelayRecognitionModel() async -> RecognitionModelDescriptor? {
            let model = RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
            guard model.runtime == .fluidAudio else { return nil }
            guard await RecognitionModelStore.shared.isModelCached(model) else {
                logRealtime("host recognition off reason=modelNotCached model=\(model.id)", stage: "relay")
                return nil
            }
            return model
        }

        /// Feeds relayed extension audio to the local recognizer off the main actor.
        func startHostRecognitionRelay(reader: RealtimeAudioRelayReader) {
            hostRecognitionRelayReader = reader
            let recognizer = activeRecognizer
            let recorder = audioHistoryRecorder
            hostRecognitionRelayTask = Task.detached(priority: .userInitiated) {
                var bufferCount = 0
                func deliver(_ buffer: AVAudioPCMBuffer) {
                    let duration = Double(buffer.frameLength) / RealtimeAudioRelay.sampleRate
                    guard duration <= RealtimeSessionStore.hostRecognitionRelayMaximumChunkDuration else {
                        RealtimeLog.warn("relay", "host dropped stalled chunk seconds=\(String(format: "%.1f", duration))")
                        return
                    }
                    bufferCount += 1
                    if bufferCount == 1 {
                        RealtimeLog.log("relay", "host first audio chunk seconds=\(String(format: "%.2f", duration))")
                    }
                    recognizer.append(buffer)
                    recorder.append(buffer)
                }
                RealtimeLog.log("relay", "host reader started")
                while !Task.isCancelled {
                    if let buffer = reader.readAvailable() {
                        deliver(buffer)
                    }
                    try? await Task.sleep(for: RealtimeSessionStore.hostRecognitionRelayPollInterval)
                }
                // Audio written before the stop still reaches the recognizer.
                if let buffer = reader.readAvailable() {
                    deliver(buffer)
                }
                RealtimeLog.log(
                    "relay",
                    "host reader stopped chunks=\(bufferCount) totalSeconds=\(String(format: "%.1f", Double(reader.totalSampleCount) / RealtimeAudioRelay.sampleRate))"
                )
            }
        }

        /// Stops reading relayed audio, then finishes recognition and translation like a microphone stop.
        func drainHostRecognitionRelay() async {
            guard let task = hostRecognitionRelayTask else { return }
            hostRecognitionRelayTask = nil
            logRealtime("host drain begin sourceLen=\(sourceText.count) pairs=\(sentencePairs.count)", stage: "relay")
            task.cancel()
            await task.value
            await activeRecognizer.stop()
            await callbackDrain.wait()
            finalizePendingRecognition()
            await translationScheduler.settle()
            audioHistoryRecorder.finish()
            hostRecognitionRelayReader?.removeAll()
            hostRecognitionRelayReader = nil
            logRealtime("host drain end sourceLen=\(sourceText.count) pairs=\(sentencePairs.count)", stage: "relay")
        }

        /// The extension stopped seeing host heartbeats and recognizes locally now. Save what the host
        /// recognized as its own history entry, then show the extension's transcript.
        func handOffHostRecognitionToExtension(state: RealtimeBroadcastState) {
            guard !isDrainingHostRecognitionRelay else { return }
            logRealtime(
                "host lost ownership phase=\(state.phase.rawValue) extensionSourceLen=\(state.sourceText.count); draining",
                stage: "relay"
            )
            isDrainingHostRecognitionRelay = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await drainHostRecognitionRelay()
                saveRealtimeHistoryIfPossible(generateTitle: true)
                usesHostRecognitionRelay = false
                isDrainingHostRecognitionRelay = false
                logRealtime("host handed off to extension", stage: "relay")
            }
        }

        /// Ends the session, first draining host recognition when relayed audio was in use.
        func endIPhoneAudioBroadcastSession(status: String, alert: RealtimeStartFailureAlert? = nil) {
            let finish = { [self] in
                finishIPhoneAudioBroadcastSession(status: status)
                if let alert {
                    handleErrorMessage(alert.message)
                    startFailureAlert = alert
                }
            }
            guard hostRecognitionRelayTask != nil else {
                finish()
                return
            }
            guard !isDrainingHostRecognitionRelay else { return }
            isDrainingHostRecognitionRelay = true
            stopBroadcastStatePolling()
            logRealtime("session ending status=\(status); draining host recognition", stage: "relay")
            Task { @MainActor [weak self] in
                await self?.drainHostRecognitionRelay()
                self?.isDrainingHostRecognitionRelay = false
                finish()
            }
        }

        func finishIPhoneAudioBroadcastSession(status: String) {
            if let task = hostRecognitionRelayTask {
                logRealtime("finish without drain; stopping host recognition", stage: "relay")
                task.cancel()
                hostRecognitionRelayTask = nil
                hostRecognitionRelayReader?.removeAll()
                hostRecognitionRelayReader = nil
                let recognizer = activeRecognizer
                Task { await recognizer.stop() }
            }
            saveRealtimeHistoryIfPossible(generateTitle: true)
            usesHostRecognitionRelay = false
            stopBroadcastStatePolling()
            isRunning = false
            isStopping = false
            activeSessionID = UUID()
            drainingSessionID = nil
            isPaused = false
            audioLevel = nil
            audioSampleCount = 0
            isIPhoneAudioCaptureReady = false
            statusText = status
            logRealtime("finished status=\(status)", stage: "broadcast")
        }
    #endif

    func startRecognition(sessionID: UUID) async throws -> Int {
        recognitionAudioPosition = 0
        #if os(macOS)
            for configuration in laneConfigurations {
                let model = configuration.recognitionModel
                if model.runtime == .mossOffline {
                    guard importedAudioURL != nil else {
                        throw RealtimeRecognizerError.unsupportedModel(model.id)
                    }
                    #if arch(arm64) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
                        guard await RealtimeHistoryMOSSReconstructor.shared.isModelCached() else {
                            throw RealtimePipelineError.modelNotDownloaded(model.title)
                        }
                    #else
                        throw RealtimeRecognizerError.unsupportedModel(model.id)
                    #endif
                    continue
                }
                guard await RecognitionModelStore.shared.isModelCached(model) else {
                    throw RealtimePipelineError.modelNotDownloaded(model.title)
                }
            }
            try await realtimePipelineCoordinator.start(
                configurations: laneConfigurations,
                primaryLaneID: primaryLaneID,
                sourceLanguage: preferences.realtimeSourceLanguage,
                targetLanguage: preferences.realtimeTargetLanguage,
                captionDisplayMode: captionDisplayMode,
                importedAudioURL: importedAudioURL,
                serializesMOSS: Self.shouldSerializeMOSS(configurations: laneConfigurations) ||
                    isRealtimeMemoryConstrained
            )
            return 16000
        #else
            await activeRecognizer.stop()

            switch preferences.realtimeRecognitionEngine {
            case .appleSpeech:
                var model = RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID)
                if !(await RecognitionModelStore.shared.isModelCached(model)) {
                    model = .appleSpeech
                }
                if preferences.realtimeRecognitionModelID != model.id {
                    preferences.setRealtimeRecognitionModelID(model.id)
                }
                statusText = Self.loadingRecognitionModelStatus(modelTitle: model.title)
                loadingRecognitionModelTitle = model.title
                defer { loadingRecognitionModelTitle = nil }
                switch model.runtime {
                case .appleSpeech:
                    try await transcriber.start(model: model, locale: speechLocale(), sessionID: sessionID)
                    activeRecognizer.set(transcriber)
                    return transcriber.sampleRate
                case .fluidAudio:
                    #if arch(arm64) && canImport(FluidAudio)
                        if let progress = await RealtimeFluidAudioEngineCache.shared.loadProgress(for: model) {
                            recognitionModelLoad = progress
                        }
                        defer { recognitionModelLoad = nil }
                        let recognizer = RealtimeFluidAudioRecognizer(delegate: self)
                        try await recognizer.start(model: model, locale: speechLocale(), sessionID: sessionID)
                        activeRecognizer.set(recognizer)
                        return recognizer.sampleRate
                    #else
                        throw RealtimeRecognizerError.unsupportedModel(model.id)
                    #endif
                case .coreML, .mossOffline, .mlxStreaming, .onnx:
                    throw RealtimeRecognizerError.unsupportedModel(model.id)
                }
            }
        #endif
    }

    public static func loadingRecognitionModelStatus(modelTitle: String) -> String {
        String(localized: "Loading \(modelTitle) to recognize speech...")
    }

    #if os(macOS)
        func startLiveCaptureBeforeRecognition() async throws {
            realtimePipelineAudioFanout.beginStartupBuffering()
            startRealtimeHistorySessionIfNeeded()
            statusText = String(localized: "Starting \(inputSource.title)...")
            switch inputSource {
            case .macAudio:
                try systemAudioCapture.requestScreenRecordingAccess()
                try await systemAudioCapture.start(sampleRate: 16000)
            case .microphone:
                try await microphoneAudioCapture.start(
                    sampleRate: 16000,
                    allowsPlayback: false
                )
            }
            await startSecondaryAudioRecordingIfNeeded(sampleRate: 16000)
        }

        func startImportedAudioTask(url: URL, sessionID: UUID) {
            let fanout = realtimePipelineAudioFanout
            let recorder = audioHistoryRecorder
            importedAudioTask = Task.detached(priority: .userInitiated) { [store = self] in
                do {
                    try await RealtimeImportedAudioReader.run(
                        url: url,
                        isPaused: {
                            await store.isPaused
                        },
                        onBuffer: { buffer in
                            let completedAudioSegment = recorder.append(buffer)
                            fanout.append(buffer)
                            let level = realtimeAudioLevel(from: buffer)
                            Task { @MainActor in
                                guard store.shouldAcceptRealtimeCallback(sessionID: sessionID)
                                else {
                                    return
                                }
                                store.updateAudioSampleCount(
                                    store.audioSampleCount + Int(buffer.frameLength),
                                    level: level
                                )
                                if completedAudioSegment {
                                    store.autosaveRealtimeHistoryIfNeeded()
                                }
                            }
                        }
                    )
                    try Task.checkCancellation()
                    await store.realtimePipelineCoordinator.finishImportedAudioInputAndWaitForOfflineRecognition()
                    try Task.checkCancellation()
                    await store.finishImportedAudioIfCurrent(sessionID: sessionID)
                } catch is CancellationError {
                    return
                } catch {
                    await store.handleImportedAudioFailure(error, sessionID: sessionID)
                }
            }
        }

        func finishImportedAudioIfCurrent(sessionID: UUID) async {
            guard shouldAcceptRealtimeCallback(sessionID: sessionID),
                  isImportedAudioSession
            else {
                return
            }
            importedAudioTask = nil
            await stop()
        }

        func handleImportedAudioFailure(_ error: Error, sessionID: UUID) async {
            guard shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
            importedAudioTask = nil
            await stop()
            handleStartFailure(error)
        }

        func startSecondaryAudioRecordingIfNeeded(sampleRate: Int) async {
            guard let secondarySource = secondaryAudioSource else { return }

            do {
                switch secondarySource {
                case .macAudio:
                    try secondarySystemAudioCapture.requestScreenRecordingAccess()
                    try await secondarySystemAudioCapture.start(sampleRate: sampleRate)
                case .microphone:
                    try await secondaryMicrophoneAudioCapture.start(sampleRate: sampleRate)
                }
                logRealtime("secondary audio recording started source=\(secondarySource.rawValue)")
            } catch {
                secondaryAudioHistoryRecorder.finish()
                secondaryAudioSource = nil
                logRealtime(
                    "secondary audio recording skipped source=\(secondarySource.rawValue) error=\(Self.describe(error))"
                )
            }
        }

        func handleSecondaryAudioFailure(_ error: Error, source: RealtimeAudioInputSource) async {
            guard secondaryAudioSource == source else { return }
            secondaryAudioHistoryRecorder.finish()
            secondaryAudioSource = nil
            switch source {
            case .macAudio:
                await secondarySystemAudioCapture.stop()
            case .microphone:
                secondaryMicrophoneAudioCapture.stop()
            }
            logRealtime("secondary audio recording stopped source=\(source.rawValue) error=\(Self.describe(error))")
            autosaveRealtimeHistoryIfNeeded()
        }
    #endif

    func ensureAppleTranslateLanguagesInstalledIfNeeded(
        providers requestedProviders: Set<RealtimeTranslationProvider>? = nil
    ) async throws {
        let allowsDownloadPrompt = allowsAppleTranslationDownloadPromptOnNextStart
        allowsAppleTranslationDownloadPromptOnNextStart = false
        let providers: Set<RealtimeTranslationProvider> = {
            if let requestedProviders {
                return requestedProviders
            }
            #if os(macOS)
                return Set(laneConfigurations.map(\.translationProvider))
            #else
                return [preferences.realtimeTranslationProvider]
            #endif
        }()
        let appleProviders = providers.filter(\.usesAppleTextTranslation)
        guard !appleProviders.isEmpty,
              let source = preferences.realtimeSourceLanguage.localeLanguage
        else {
            return
        }

        let targetOption = preferences.realtimeTargetLanguage
        let target = targetOption.localeLanguage
        guard !RealtimeLanguageMatcher.matches(source, target) else { return }

        guard AppleTranslationService.shared.isAvailable else {
            throw LocalProviderError.notAvailable(AppleTranslationService.shared.availabilityStatus)
        }

        statusText = String(localized: "Checking Apple Translate languages...")
        let languagePair = AppleTranslationErrorFormatter.languagePairDescription(
            source: source,
            target: targetOption
        )
        let strategies: Set<AppleTranslationAvailabilityStrategy> = Set(appleProviders.map {
            $0 == .appleTranslationRealtime ? .lowLatency : .automatic
        })
        for strategy in strategies {
            var status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                source: source,
                target: target,
                strategy: strategy
            )
            if status == .supported, allowsDownloadPrompt {
                await requestAppleTranslationLanguageDownload(source: source, target: target, strategy: strategy)
                status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                    source: source,
                    target: target,
                    strategy: strategy
                )
                // iOS keeps downloading after its prompt is dismissed and won't prompt again
                // meanwhile, so offering Download again would loop without visible effect.
                if status == .supported {
                    let message = NSLocalizedString(
                        "iOS is downloading this language pair in the background. Try again in a moment.",
                        comment: "Shown when realtime Apple Translate is still waiting for a language pack download"
                    )
                    throw LocalProviderError.translationFailed(
                        AppleTranslationErrorFormatter.withLanguagePair(message, languagePair: languagePair)
                    )
                }
            }
            if let error = Self.appleTranslateLanguagePreflightFailure(
                status: status,
                languagePair: languagePair
            ) {
                throw error
            }
        }
    }

    func requestAppleTranslationLanguageDownload(
        source: Locale.Language,
        target: Locale.Language,
        strategy: AppleTranslationAvailabilityStrategy
    ) async {
        finishAppleTranslationLanguageDownload(requestID: appleTranslationDownloadRequestID)
        var configuration: TranslationSession.Configuration
        if #available(iOS 26.4, macOS 26.4, *), strategy == .lowLatency {
            configuration = .init(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            configuration = .init(source: source, target: target)
        }
        if var previous = appleTranslationDownloadConfiguration,
           previous.source == configuration.source,
           previous.target == configuration.target,
           Self.hasSameStrategy(previous, configuration)
        {
            previous.invalidate()
            configuration = previous
        }
        let requestID = UUID()
        logRealtime("apple translate download requested strategy=\(strategy)")
        await withCheckedContinuation { continuation in
            appleTranslationDownloadRequestID = requestID
            isAppleTranslationDownloadPromptPresented = false
            appleTranslationDownloadContinuation = continuation
            appleTranslationDownloadConfiguration = configuration
            // Starts outside the realtime view (e.g. the floating caption window) have no
            // `.translationTask` host; fail the preflight instead of waiting forever.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self,
                      self.appleTranslationDownloadRequestID == requestID,
                      !self.isAppleTranslationDownloadPromptPresented
                else {
                    return
                }
                self.logRealtime("apple translate download prompt not presented")
                self.finishAppleTranslationLanguageDownload(requestID: requestID)
            }
        }
    }

    /// Called from a realtime view's `.translationTask` with the session for
    /// `appleTranslationDownloadConfiguration`.
    public func prepareAppleTranslationLanguageDownload(using session: TranslationSession) async {
        guard let requestID = appleTranslationDownloadRequestID else { return }
        // Keeps the prompt timeout from firing while the user decides.
        isAppleTranslationDownloadPromptPresented = true
        do {
            try await session.prepareTranslation()
            logRealtime("apple translate download prepared")
        } catch {
            logRealtime("apple translate download failed error=\(Self.describe(error))")
        }
        finishAppleTranslationLanguageDownload(requestID: requestID)
    }

    static func hasSameStrategy(
        _ lhs: TranslationSession.Configuration,
        _ rhs: TranslationSession.Configuration
    ) -> Bool {
        guard #available(iOS 26.4, macOS 26.4, *) else { return true }
        return lhs.preferredStrategy == rhs.preferredStrategy
    }

    func finishAppleTranslationLanguageDownload(requestID: UUID?) {
        guard let requestID, requestID == appleTranslationDownloadRequestID else { return }
        appleTranslationDownloadRequestID = nil
        appleTranslationDownloadContinuation?.resume()
        appleTranslationDownloadContinuation = nil
    }

    func handleRecognized(_ result: RealtimeRecognitionResult) {
        beginCaptionTrace(
            "asr",
            "state=\(result.state) at=\(result.audioOffset.map { String(format: "%.2fs", $0) } ?? "-") " +
                "text=\(RealtimeLog.text(result.text, limit: 64))"
        )
        defer { captionUpdateCause = "-" }
        let previousSegments = translationState.sourceSegments
        let previousPairCount = sentencePairs.count
        let previousDisplayedTranslationLength = translatedText.count + pendingTranslatedText.count
        let recognizedSourceText = transcriptAccumulator.append(result, afterLongSilence: false)
        if sourceText != recognizedSourceText {
            sourceText = recognizedSourceText
        }
        updateTranscriptPresentation()
        let recognitionTimings = result.snapshot.map(Self.recognitionTimings(in:)) ?? []
        recognitionAudioPosition = max(
            recognitionAudioPosition,
            result.audioOffset ?? recognitionTimings.last?.endTime ?? 0
        )
        if usesRealtimeSessionHistory {
            historySessionBuilder.noteSource(
                committedCount: translationState.sourceSegments.count,
                hasText: !pendingSourceText.isEmpty
            )
            historySessionBuilder.noteRecognition(timings: recognitionTimings)
        }
        Self.logSourceSegmentChange(
            from: previousSegments,
            to: translationState.sourceSegments,
            pending: pendingSourceText,
            result: result
        )
        let displayedTranslationLength = translatedText.count + pendingTranslatedText.count
        if displayedTranslationLength < previousDisplayedTranslationLength {
            RealtimeLog.warn(
                "align",
                """
                translation shrank len=\(previousDisplayedTranslationLength)->\(displayedTranslationLength) \
                pairs=\(previousPairCount)->\(sentencePairs.count) segs=\(previousSegments.count)->\(translationState.sourceSegments.count)
                """
            )
        }
        statusText = result
            .confidence > 0 ? String(localized: "Recognizing") : String(localized: "Listening to \(inputSource.title)")
        scheduleTranslation()
    }

    /// Word timings when the recognizer reports them; otherwise each timed segment is one span.
    static func recognitionTimings(
        in snapshot: RealtimeRecognitionSnapshot
    ) -> [RealtimeRecognitionTokenTiming] {
        guard snapshot.tokenTimings.isEmpty else { return snapshot.tokenTimings }
        return (snapshot.stableSegments + [snapshot.pendingSegment].compactMap(\.self)).map {
            RealtimeRecognitionTokenTiming(
                token: $0.text,
                startTime: $0.startOffset,
                endTime: $0.endOffset,
                confidence: 0.5
            )
        }
    }

    func finalizePendingRecognition() {
        let pending = transcriptAccumulator.pendingSentenceText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty else { return }

        assignIfChanged(&sourceText, transcriptAccumulator.commitPartial())
        updateTranscriptPresentation()
        scheduleTranslation()
    }

    func updateAudioSampleCount(_ count: Int, level: Float?) {
        audioSampleCount = count
        audioLevel = level
    }

    func scheduleTranslation() {
        let provider = preferences.realtimeTranslationProvider
        guard provider.performsTranslation else {
            cancelTranslationWork()
            translationState.resetTranslationResults()
            syncTranslationStatePresentation()
            updateStatusAfterTranslationActivity()
            return
        }
        let stableSourceText = translationSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let partialSourceText = pendingSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stableSourceText.isEmpty || !partialSourceText.isEmpty else {
            cancelTranslationWork()
            translationState.clearStableTranslation()
            syncTranslationStatePresentation()
            return
        }

        guard hasRequiredLanguageSelection else {
            logRealtime("missingLanguage clearsTranslation=true", stage: "tx")
            cancelTranslationWork()
            translationState.resetTranslationResults()
            syncTranslationStatePresentation()
            statusText = String(localized: "Choose source and target languages to start")
            return
        }

        let sourceLanguage = preferences.realtimeSourceLanguage
        let source = sourceLanguage.localeLanguage
        let targetOption = preferences.realtimeTargetLanguage
        let target = targetOption.localeLanguage
        let languagePair = AppleTranslationErrorFormatter.languagePairDescription(
            source: source,
            target: targetOption
        )

        if let source, RealtimeLanguageMatcher.matches(source, target) {
            logRealtime("sameLanguage provider=\(provider.rawValue) skipsTranslation=true", stage: "tx")
            cancelTranslationWork()
            translationState.applySameLanguageTranslation()
            syncTranslationStatePresentation()
            statusText = String(localized: "Source and target are the same (\(languagePair))")
            return
        }

        if stableSourceText.isEmpty {
            translationState.clearStableTranslation()
            syncTranslationStatePresentation()
        } else {
            translationState.updateCachedSentencePairs(
                provider: provider,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetOption
            )
            syncTranslationStatePresentation()
            enqueueFinalTranslationRequests(
                provider: provider,
                sourceLanguage: sourceLanguage,
                source: source,
                targetLanguage: targetOption
            )
        }
        schedulePartialTranslation(
            provider: provider,
            sourceLanguage: sourceLanguage,
            source: source,
            targetLanguage: targetOption
        )
        updateStatusAfterTranslationActivity()
    }

    func configureTranslationScheduler() {
        translationScheduler.handlers = .init(
            translate: { try await RealtimeTranslationService.translate($0) },
            finalResult: { [weak self] request, result in
                self?.applyFinalTranslationResult(result, request: request)
            },
            finalFailure: { [weak self] request, error in
                self?.handleTranslationError(error, request: request, kind: "final")
            },
            partialResult: { [weak self] request, result in
                self?.applyPartialTranslationResult(result, request: request)
            },
            partialFailure: { [weak self] request, error in
                self?.handleTranslationError(error, request: request, kind: "partial")
            },
            finalIdle: { [weak self] in
                guard let self else { return }
                updateStatusAfterTranslationActivity()
                if isPaused {
                    saveRealtimeHistoryIfPossible()
                }
            },
            partialIdle: { [weak self] in self?.updateStatusAfterTranslationActivity() }
        )
    }

    func handleTranslationError(_ error: Error, request: RealtimeTextTranslationRequest, kind: String) {
        if kind == "final" {
            translationState.finishFinalTranslationRequest(request)
            syncTranslationStatePresentation()
        }
        let message = Self.translationErrorMessage(
            error,
            source: request.source,
            target: request.targetLanguage,
            provider: request.provider
        )
        RealtimeLog.warn("tx", "\(kind) error src=\(RealtimeLog.text(request.translationText)) error=\(message)")
        handleErrorMessage(message)
    }

    func saveRealtimeHistoryIfPossible(generateTitle: Bool = false) {
        if let session = currentRealtimeHistorySession() {
            if saveRealtimeHistorySession(session, event: "saved"), generateTitle {
                generateRealtimeHistoryTitleIfNeeded(for: session)
            }
            return
        }
        #if os(iOS)
            if inputSource == .iphoneAudio {
                logRealtime("history skipped reason=missingBroadcastRealtimeSession")
                return
            }
        #endif

        guard let snapshot = Self.historySnapshot(
            sourceText: sourceText,
            translatedText: translatedText,
            pendingTranslatedText: pendingTranslatedText,
            checkpoint: &historyCheckpoint
        ) else {
            logRealtime(
                """
                history skipped sourceLen=\(sourceText.count) translatedLen=\(translatedText.count) \
                pendingTranslationLen=\(pendingTranslatedText.count)
                """
            )
            return
        }

        do {
            try TranslationHistoryService.shared.saveThrowing(
                requestID: UUID(),
                sourceText: snapshot.sourceText,
                resultText: snapshot.translatedText,
                actionName: TranslationRecord.realtimeActionName,
                targetLanguage: preferences.realtimeTargetLanguage.englishName,
                modelID: preferences.realtimeTranslationProvider.modelID,
                modelDisplayName: preferences.realtimeTranslationProvider.model.displayName,
                duration: 0
            )
            historyCheckpoint.acknowledge(snapshot)
            logRealtime(
                """
                history saved sourceLen=\(snapshot.sourceText.count) translatedLen=\(snapshot.translatedText.count)
                """
            )
        } catch {
            logRealtime("history save failed error=\(Self.describe(error))")
        }
    }

    func autosaveRealtimeHistoryIfNeeded(now: Date = Date()) {
        guard isRunning else { return }
        // Throttle before building the session: this runs on every recognition update.
        if let lastRealtimeHistoryAutosaveAt {
            let delay = Self.realtimeHistoryAutosaveInterval - now.timeIntervalSince(lastRealtimeHistoryAutosaveAt)
            if delay > 0 {
                if realtimeHistoryAutosaveTask == nil {
                    scheduleRealtimeHistoryAutosave(after: delay)
                }
                return
            }
        }

        guard let session = currentRealtimeHistorySession(),
              session.segments != lastRealtimeHistoryAutosaveSegments ||
              session.audioRecordings != lastRealtimeHistoryAutosaveRecordings ||
              session.tracks != lastRealtimeHistoryAutosaveTracks
        else {
            return
        }

        _ = saveRealtimeHistorySession(session, at: now, event: "autosaved")
    }

    func scheduleRealtimeHistoryAutosave(after delay: TimeInterval) {
        realtimeHistoryAutosaveTask?.cancel()
        realtimeHistoryAutosaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.realtimeHistoryAutosaveTask = nil
            self?.autosaveRealtimeHistoryIfNeeded()
        }
    }

    func saveRealtimeHistorySession(
        _ session: RealtimeHistorySession,
        at date: Date = Date(),
        event: String
    ) -> Bool {
        realtimeHistoryAutosaveTask?.cancel()
        realtimeHistoryAutosaveTask = nil
        do {
            try TranslationHistoryService.shared.saveRealtimeSession(session)
            lastRealtimeHistoryAutosaveAt = date
            lastRealtimeHistoryAutosaveSegments = session.segments
            lastRealtimeHistoryAutosaveRecordings = session.audioRecordings
            lastRealtimeHistoryAutosaveTracks = session.tracks
            return true
        } catch {
            logRealtime("history session save failed event=\(event) error=\(Self.describe(error))")
            return false
        }
    }

    func generateRealtimeHistoryTitleIfNeeded(for session: RealtimeHistorySession) {
        let requestID = session.requestID
        guard session.generatedTitle == nil,
              !realtimeHistoryTitleRequestIDs.contains(requestID),
              !session.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        realtimeHistoryTitleRequestIDs.insert(requestID)
        realtimeHistoryTitleTasks[requestID] = Task { @MainActor [weak self] in
            defer {
                self?.realtimeHistoryTitleTasks[requestID] = nil
            }
            do {
                guard let title = try await RealtimeHistoryTitleGenerator.generateTitle(for: session.sourceText) else {
                    return
                }
                try TranslationHistoryService.shared.updateRealtimeGeneratedTitle(
                    requestID: requestID,
                    title: title
                )
                self?.logRealtime("history title generated request=\(requestID.uuidString.prefix(8))")
            } catch {
                self?.logRealtime("history title generation failed error=\(Self.describe(error))")
            }
        }
    }

    func currentRealtimeHistorySession() -> RealtimeHistorySession? {
        #if os(iOS)
            if inputSource == .iphoneAudio, !usesHostRecognitionRelay {
                guard [.appleTranslator, .transcriptionOnly].contains(preferences.realtimeTranslationProvider) else {
                    return nil
                }
                var session = latestBroadcastRealtimeHistorySession
                session?.inputSourceID = historyInputSourceID(for: inputSource)
                return session
            }
        #endif

        guard usesRealtimeSessionHistory else { return nil }
        syncRealtimeHistorySession()
        #if os(macOS)
            let primaryConfiguration = primaryLaneConfiguration
            let modelID = primaryConfiguration?.translationProvider.modelID ??
                preferences.realtimeTranslationProvider.modelID
            let modelDisplayName = primaryConfiguration?.translationProvider.model.displayName ??
                preferences.realtimeTranslationProvider.model.displayName
        #else
            let modelID = preferences.realtimeTranslationProvider.modelID
            let modelDisplayName = preferences.realtimeTranslationProvider.model.displayName
        #endif
        #if os(macOS)
            let tracks = realtimePipelineCoordinator.tracks
            let transcriptionModels = tracks.map {
                RealtimeHistoryTranscriptionModel(
                    source: activeHistoryAudioSource,
                    modelID: $0.recognitionModelID,
                    modelDisplayName: $0.recognitionModelDisplayName
                )
            }
            let historyPrimaryTrackID: UUID? = primaryLaneID
        #else
            let tracks: [RealtimeHistoryTrack] = []
            let transcriptionModels: [RealtimeHistoryTranscriptionModel] = []
            let historyPrimaryTrackID: UUID? = nil
        #endif
        var session = historySessionBuilder.makeSession(
            inputSource: activeHistoryAudioSource.title,
            sourceLanguage: preferences.realtimeSourceLanguage.englishName,
            targetLanguage: preferences.realtimeTargetLanguage.englishName,
            modelID: modelID,
            modelDisplayName: modelDisplayName,
            transcriptionModels: transcriptionModels,
            tracks: tracks,
            primaryTrackID: historyPrimaryTrackID
        )
        session?.audioRecordings = audioHistoryRecordingsSnapshot()
        session?.inputSourceID = activeHistoryInputSourceID
        #if os(macOS)
            session?.tracks = tracks
            session?.primaryTrackID = primaryLaneID
        #endif
        return session
    }

    func historyInputSourceID(for inputSource: RealtimeAudioInputSource) -> RealtimeHistoryInputSource {
        switch inputSource {
        #if os(macOS)
            case .macAudio:
                return .macAudio
        #endif
        case .microphone:
            return .microphone
        #if os(iOS)
            case .iphoneAudio:
                return .iphoneAudio
        #endif
        }
    }

    func resetRealtimeHistoryAutosave() {
        realtimeHistoryAutosaveTask?.cancel()
        realtimeHistoryAutosaveTask = nil
        lastRealtimeHistoryAutosaveAt = nil
        lastRealtimeHistoryAutosaveSegments = nil
        lastRealtimeHistoryAutosaveRecordings = nil
        lastRealtimeHistoryAutosaveTracks = nil
    }

    var usesRealtimeSessionHistory: Bool {
        #if os(macOS)
            return !laneConfigurations.isEmpty
        #else
            return true
        #endif
    }

    func startRealtimeHistorySessionIfNeeded() {
        resetRealtimeHistoryAutosave()
        if usesRealtimeSessionHistory {
            historySessionBuilder.start(recognitionTimelineBase: recognitionAudioPosition)
            audioHistoryRecorder.start(
                requestID: historySessionBuilder.requestID,
                source: activeHistoryAudioSource
            )
            #if os(macOS)
                if let secondarySource = secondaryHistoryInputSource {
                    secondaryAudioSource = secondarySource
                    secondaryAudioHistoryRecorder.start(
                        requestID: historySessionBuilder.requestID,
                        source: historyAudioSource(for: secondarySource)
                    )
                } else {
                    secondaryAudioSource = nil
                    secondaryAudioHistoryRecorder.reset()
                }
            #else
                secondaryAudioHistoryRecorder.reset()
            #endif
        } else {
            historySessionBuilder.reset()
            audioHistoryRecorder.reset()
            secondaryAudioHistoryRecorder.reset()
            #if os(macOS)
                secondaryAudioSource = nil
            #endif
        }
    }

    func audioHistoryRecordingsSnapshot() -> [RealtimeHistoryAudioRecording] {
        [
            audioHistoryRecorder.snapshot(),
            secondaryAudioHistoryRecorder.snapshot(),
        ]
        .compactMap { $0 }
        .sorted { $0.source.rawValue < $1.source.rawValue }
    }

    func historyAudioSource(for inputSource: RealtimeAudioInputSource) -> RealtimeHistoryAudioSource {
        switch inputSource {
        #if os(macOS)
            case .macAudio:
                return .macAudio
        #endif
        case .microphone:
            return .microphone
        #if os(iOS)
            case .iphoneAudio:
                return .microphone
        #endif
        }
    }

    var activeHistoryAudioSource: RealtimeHistoryAudioSource {
        #if os(macOS)
            isImportedAudioSession ? .importedAudio : historyAudioSource(for: inputSource)
        #else
            historyAudioSource(for: inputSource)
        #endif
    }

    var activeHistoryInputSourceID: RealtimeHistoryInputSource {
        #if os(macOS)
            isImportedAudioSession ? .importedAudio : historyInputSourceID(for: inputSource)
        #else
            historyInputSourceID(for: inputSource)
        #endif
    }

    #if os(macOS)
        var secondaryHistoryInputSource: RealtimeAudioInputSource? {
            guard !isImportedAudioSession, preferences.realtimeDualInputHistoryRecordingEnabled else { return nil }
            switch inputSource {
            case .macAudio:
                return .microphone
            case .microphone:
                return .macAudio
            }
        }
    #endif

    func syncRealtimeHistorySession() {
        guard usesRealtimeSessionHistory else { return }
        #if os(iOS)
            if !preferences.realtimeTranslationProvider.performsTranslation {
                historySessionBuilder.sync(pairs: translationState.sourceOnlyPairs, allowsUntranslated: true)
                return
            }
        #endif
        historySessionBuilder.sync(pairs: realtimeHistoryPairs())
    }

    func realtimeHistoryPairs() -> [SentencePair] {
        return Self.historyPairs(
            sentencePairs: sentencePairs,
            pendingSourceText: pendingSourceText,
            pendingTranslatedText: pendingTranslatedText,
            sourceText: sourceText,
            translatedText: translatedText
        )
    }

    func handleErrorMessage(_ message: String) {
        logRealtime("errorMessage \(message)")
        errorMessage = message
        statusText = String(localized: "Error")
    }

    func handleStartFailure(_ error: Error) {
        handleErrorMessage(Self.describe(error))
        startFailureAlert = Self.startFailureAlert(for: error)
    }

    func handleRuntimeFailure(_ error: Error, context: String) async {
        guard !Self.isCancellationError(error) else { return }
        if isStarting, !isStopping {
            // start() surfaces it before marking the session running.
            pendingStartFailure = pendingStartFailure ?? error
            logRealtime("runtimeFailure deferred to start context=\(context)")
            return
        }
        guard isRunning, !isStopping else {
            logRealtime(
                "runtimeFailure ignored context=\(context) running=\(isRunning) stopping=\(isStopping)"
            )
            return
        }

        let alert = Self.startFailureAlert(for: error)
        logRealtime("runtimeFailure context=\(context) \(alert.message)")
        await stop()
        handleErrorMessage(alert.message)
        startFailureAlert = alert
    }

    nonisolated static func startFailureAlertMessage(for error: Error) -> String {
        describe(error)
    }

    public nonisolated static func realtimeErrorDescription(for error: Error) -> String {
        describe(error)
    }

    #if os(iOS)
        nonisolated static func iPhoneAudioBroadcastFailureAlert(
            for state: RealtimeBroadcastState,
            referenceDate: Date = Date()
        ) -> RealtimeStartFailureAlert {
            RealtimeStartFailureAlert(
                title: "iPhone Audio Failed",
                message: iPhoneAudioBroadcastFailureMessage(for: state, referenceDate: referenceDate)
            )
        }

        nonisolated static func isStaleActiveIPhoneAudioBroadcast(_ state: RealtimeBroadcastState) -> Bool {
            if state.audioSampleCount > 0 {
                return true
            }

            switch state.phase {
            case .broadcasting, .recognizing, .translating, .paused, .stopping, .failed:
                return true
            case .idle, .waiting, .stopped:
                return false
            }
        }

        nonisolated static func isIPhoneAudioBroadcastWaitTimedOut(
            _ state: RealtimeBroadcastState,
            referenceDate: Date = Date(),
            timeout: TimeInterval = broadcastPickerWaitTimeout
        ) -> Bool {
            state.phase == .waiting &&
                state.audioSampleCount == 0 &&
                referenceDate.timeIntervalSince(state.lastUpdatedAt) >= timeout
        }

        nonisolated static func iPhoneAudioBroadcastFailureMessage(
            for state: RealtimeBroadcastState,
            referenceDate: Date
        ) -> String {
            if let errorMessage = state.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
               !errorMessage.isEmpty
            {
                return errorMessage
            }

            if state.isStale(referenceDate: referenceDate) {
                let elapsed = max(0, Int(referenceDate.timeIntervalSince(state.lastUpdatedAt).rounded()))
                return """
                The iPhone Audio broadcast stopped reporting status after \(elapsed) seconds. \
                Last phase: \(state.phase.rawValue). Audio samples received: \(state.audioSampleCount). \
                iOS may have terminated the broadcast upload extension before it could return an error.
                """
            }

            return """
            The iPhone Audio broadcast stopped without reporting a detailed error. \
            Last phase: \(state.phase.rawValue). Audio samples received: \(state.audioSampleCount).
            """
        }
    #endif

    nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    nonisolated static func startFailureAlert(for error: Error) -> RealtimeStartFailureAlert {
        RealtimeStartFailureAlert(
            title: String(localized: "Realtime Failed"),
            message: startFailureAlertMessage(for: error),
            offersAppleTranslationDownload: {
                if case .languagePackNotInstalled? = error as? LocalProviderError {
                    return true
                }
                return false
            }()
        )
    }

    nonisolated static func appleTranslateLanguagePreflightFailure(
        status: LanguageAvailability.Status,
        languagePair: String
    ) -> LocalProviderError? {
        switch status {
        case .installed:
            return nil
        case .supported:
            return .languagePackNotInstalled(languagePair: languagePair)
        case .unsupported:
            return .translationFailed(AppleTranslationErrorFormatter.withLanguagePair(
                "Apple Translate does not support this language pair.",
                languagePair: languagePair
            ))
        @unknown default:
            return .translationFailed(AppleTranslationErrorFormatter.withLanguagePair(
                "Apple Translate could not confirm this language pair is installed.",
                languagePair: languagePair
            ))
        }
    }
}
