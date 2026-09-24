#if os(macOS) || os(iOS)
    #if os(iOS)
        import UIKit
    #endif
    import AVFoundation
    import Combine
    import CoreMedia
    import Foundation
    import os
    #if canImport(Translation)
        import Translation
    #endif

    private let realtimeLogger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Realtime")

    public struct RealtimeStartFailureAlert: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let message: String

        public init(id: UUID = UUID(), title: String, message: String) {
            self.id = id
            self.title = title
            self.message = message
        }
    }

    @MainActor
    public final class RealtimeSessionStore: ObservableObject {
        public static let shared = RealtimeSessionStore()
        private static let captionLineDisplayLimit = 160
        private static let realtimeHistoryAutosaveInterval: TimeInterval = 5

        @Published public var inputSource: RealtimeAudioInputSource = .default
        @Published public var showCaptions: Bool {
            didSet {
                guard showCaptions != oldValue else { return }
                preferences.setRealtimeShowCaptions(showCaptions)
            }
        }

        @Published public var captionDisplayMode: RealtimeCaptionDisplayMode = .bilingual {
            didSet {
                guard captionDisplayMode != oldValue else { return }
                #if os(macOS)
                    realtimePipelineCoordinator.updateCaptionDisplayMode(captionDisplayMode)
                #endif
                refreshCaptionLines(event: "captionDisplayModeChanged")
            }
        }

        @Published public private(set) var isRunning = false
        @Published public private(set) var isStarting = false
        @Published public private(set) var isStopping = false
        @Published public private(set) var isPaused = false
        @Published public private(set) var sourceText = ""
        @Published public private(set) var translatedText = ""
        @Published public private(set) var translationSourceText = ""
        @Published public private(set) var sentencePairs: [SentencePair] = []
        @Published public private(set) var pendingSourceText = ""
        @Published public private(set) var pendingTranslatedText = ""
        @Published public private(set) var captionLines: [RealtimeCaptionLine] = []
        @Published public private(set) var statusText = String(localized: "Ready")
        @Published public private(set) var errorMessage: String?
        @Published public private(set) var startFailureAlert: RealtimeStartFailureAlert?
        @Published public private(set) var audioLevel: Float?
        @Published public private(set) var audioSampleCount = 0
        #if os(macOS)
            @Published public private(set) var laneConfigurations: [RealtimeLaneConfiguration] = []
            @Published public private(set) var laneSnapshots: [RealtimeLaneSnapshot] = []
            @Published public private(set) var primaryLaneID = UUID()
            @Published public private(set) var isRealtimeMemoryConstrained = false
            @Published public private(set) var importedAudioURL: URL?
        #endif

        public var audioLevelFraction: Double {
            guard let audioLevel else { return 0 }
            return min(max((Double(audioLevel) + 60) / 60, 0), 1)
        }

        public var hasRequiredLanguageSelection: Bool {
            return RealtimeSetupPromptRequirement.hasRequiredLanguageSelection(
                sourceLanguage: preferences.realtimeSourceLanguage,
                targetLanguage: preferences.realtimeTargetLanguage,
                requiresTargetLanguage: preferences.realtimeTranslationProvider.performsTranslation
            )
        }

        private nonisolated let transcriber = RealtimeLiveSpeechTranscriber()
        private nonisolated let activeRecognizer = RealtimeRecognizerSlot()
        private nonisolated let callbackDrain = RealtimeCallbackDrain()
        #if os(macOS)
            private nonisolated let systemAudioCapture = RealtimeSystemAudioCapture()
            private nonisolated let secondarySystemAudioCapture = RealtimeSystemAudioCapture()
            private nonisolated let realtimePipelineAudioFanout = RealtimePipelineAudioFanout()
            private let realtimePipelineCoordinator: RealtimePipelineCoordinator
        #endif
        private nonisolated let microphoneAudioCapture = RealtimeMicrophoneAudioCapture()
        #if os(macOS)
            private nonisolated let secondaryMicrophoneAudioCapture = RealtimeMicrophoneAudioCapture()
        #endif
        private nonisolated let audioHistoryRecorder = RealtimeAudioHistoryRecorder()
        private nonisolated let secondaryAudioHistoryRecorder = RealtimeAudioHistoryRecorder()

        private let preferences: AppPreferences
        private var transcriptAccumulator = RealtimeTranscriptAccumulator()
        private var translationState = RealtimeIncrementalTranslationState()
        private var presentationSourceSegments: [String] = []
        private var captionClearAnchor = RealtimeCaptionDisplayClearAnchor.empty
        private var historyCheckpoint = RealtimeHistoryCheckpoint()
        private var historySessionBuilder = RealtimeHistorySessionBuilder()
        private var lastRealtimeHistoryAutosaveAt: Date?
        private var lastRealtimeHistoryAutosaveSegments: [RealtimeHistorySegment]?
        private var lastRealtimeHistoryAutosaveRecordings: [RealtimeHistoryAudioRecording]?
        private var lastRealtimeHistoryAutosaveTracks: [RealtimeHistoryTrack]?
        #if os(macOS)
            private var secondaryAudioSource: RealtimeAudioInputSource?
            private var importedAudioTask: Task<Void, Never>?
            private var isImportedAudioSession = false
            private var preMOSSRecognitionModelIDs: [UUID: String] = [:]
        #endif
        private var finalTranslationTask: Task<Void, Never>?
        private var partialTranslationTask: Task<Void, Never>?
        private var realtimeHistoryAutosaveTask: Task<Void, Never>?
        private var realtimeHistoryTitleTasks: [UUID: Task<Void, Never>] = [:]
        private var realtimeHistoryTitleRequestIDs: Set<UUID> = []
        private var lastBroadcastStateLogSignature: String?
        private var queuedFinalTranslationRequests: [RealtimeTextTranslationRequest] = []
        private var latestPartialTranslationRequest: RealtimeTextTranslationRequest?
        private var nextPartialTranslationAllowedAt: Date?
        private var activeSessionID = UUID()
        private var drainingSessionID: UUID?
        #if os(iOS)
            public static let broadcastUploadExtensionBundleIdentifier = "com.zanderwang.AITranslator.BroadcastUpload"
            nonisolated static let broadcastPickerWaitTimeout: TimeInterval = 15

            private let broadcastStateStore: RealtimeBroadcastStateStore?
            private var broadcastStatePollingTask: Task<Void, Never>?
            private var foregroundOnlyObservers: [NSObjectProtocol] = []
            private var latestBroadcastRealtimeHistorySession: RealtimeHistorySession?
        #endif

        public init(preferences: AppPreferences = .shared) {
            #if os(macOS)
                realtimePipelineCoordinator = RealtimePipelineCoordinator(
                    audioFanout: realtimePipelineAudioFanout
                )
            #endif
            self.preferences = preferences
            showCaptions = preferences.realtimeShowCaptions
            #if os(iOS)
                broadcastStateStore = RealtimeBroadcastStateStore()
            #endif
            transcriber.delegate = self
            #if os(macOS)
                systemAudioCapture.delegate = self
                secondarySystemAudioCapture.delegate = self
                let persistedLanes = RealtimeLaneConfigurationPersistence.load(
                    defaults: .standard,
                    fallbackRecognitionModelID: preferences.realtimeRecognitionModelID,
                    fallbackTranslationProvider: preferences.realtimeTranslationProvider
                )
                laneConfigurations = persistedLanes.configurations
                primaryLaneID = persistedLanes.primaryLaneID
                if let primaryConfiguration = persistedLanes.configurations.first(where: {
                    $0.id == persistedLanes.primaryLaneID
                }) {
                    preferences.setRealtimeRecognitionModelID(primaryConfiguration.recognitionModelID)
                    preferences.setRealtimeTranslationProvider(primaryConfiguration.translationProvider)
                }
                laneSnapshots = persistedLanes.configurations.map {
                    RealtimeLaneSnapshot(configuration: $0)
                }
                realtimePipelineCoordinator.onSnapshotsChanged = { [weak self] snapshots in
                    self?.applyLaneSnapshots(snapshots)
                }
                realtimePipelineCoordinator.onFailure = { [weak self] _, error in
                    Task { @MainActor [weak self] in
                        await self?.handleRuntimeFailure(error, context: "pipeline")
                    }
                }
                realtimePipelineCoordinator.onMemoryPressureChanged = { [weak self] constrained in
                    self?.isRealtimeMemoryConstrained = constrained
                }
                realtimePipelineCoordinator.onLaneTerminated = { [weak self] laneID, message in
                    guard let self else { return }
                    self.laneConfigurations.removeAll { $0.id == laneID }
                    self.laneSnapshots.removeAll { $0.id == laneID }
                    self.persistLaneConfiguration()
                    self.handleErrorMessage(message)
                }
            #endif
            microphoneAudioCapture.delegate = self
            #if os(macOS)
                secondaryMicrophoneAudioCapture.delegate = self
            #endif
            #if os(iOS)
                registerForegroundOnlyLifecycle()
            #endif
            if SnapshotLaunchArguments.isSnapshotMode(),
               let fixture = SnapshotLaunchArguments.fixture()
            {
                #if os(macOS)
                    if fixture == .macRealtimeMultiLane {
                        let locale = SnapshotLocaleCatalog.current()
                        preferences.setRealtimeSourceLanguage(.english, reason: "Snapshot fixture")
                        preferences.setRealtimeTargetLanguage(locale.targetLanguage, reason: "Snapshot fixture")
                        let laneFixture = SnapshotFixtureData.macRealtimeLaneSnapshots()
                        applyLaneSnapshotFixture(
                            laneFixture.snapshots,
                            primaryLaneID: laneFixture.primaryLaneID
                        )
                        isRunning = true
                        statusText = String(localized: "Listening to \(inputSource.title)")
                    } else if let realtimeFixture = SnapshotFixtureData.realtimeFixture(for: fixture) {
                        applySnapshotFixture(realtimeFixture)
                    }
                #else
                    if let realtimeFixture = SnapshotFixtureData.realtimeFixture(for: fixture) {
                        applySnapshotFixture(realtimeFixture)
                    }
                #endif
            }
        }

        deinit {
            #if os(iOS)
                for observer in foregroundOnlyObservers {
                    NotificationCenter.default.removeObserver(observer)
                }
            #endif
        }

        #if os(macOS)
            public var canAddRealtimeLane: Bool {
                laneConfigurations.count < RealtimePipelineCoordinator.maximumLaneCount &&
                    !isRealtimeMemoryConstrained
            }

            public var primaryLaneConfiguration: RealtimeLaneConfiguration? {
                laneConfigurations.first(where: { $0.id == primaryLaneID }) ?? laneConfigurations.first
            }

            public var hasImportedAudio: Bool {
                importedAudioURL != nil
            }

            public var hasMOSSLane: Bool {
                laneConfigurations.contains {
                    $0.recognitionModelID == RecognitionModelDescriptor.mossTranscribeDiarize.id
                }
            }

            public var canPauseCurrentSession: Bool {
                !hasMOSSLane
            }

            public var laneConfigurationStartBlocker: RealtimeStartBlocker? {
                Self.startConfigurationBlocker(
                    configurations: laneConfigurations,
                    hasImportedAudio: hasImportedAudio,
                    isMemoryConstrained: isRealtimeMemoryConstrained
                )
            }

            nonisolated static func startConfigurationBlocker(
                configurations: [RealtimeLaneConfiguration],
                hasImportedAudio: Bool,
                isMemoryConstrained: Bool,
                physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
            ) -> RealtimeStartBlocker? {
                guard !configurations.isEmpty else {
                    return .missingLane
                }
                guard !isMemoryConstrained else {
                    return .memoryPressure
                }
                for configuration in configurations {
                    let model: RecognitionModelDescriptor
                    if configuration.recognitionModelID == RecognitionModelDescriptor.mossTranscribeDiarize.id {
                        model = .mossTranscribeDiarize
                    } else {
                        guard let descriptor = RecognitionModelStore.descriptor(
                            forModelID: configuration.recognitionModelID
                        ),
                            RecognitionModelStore.selectableModels.contains(where: { $0.id == descriptor.id })
                        else {
                            return .unsupportedRecognitionModel(configuration.recognitionModelID)
                        }
                        model = descriptor
                    }
                    if model.runtime == .mossOffline {
                        guard RecognitionModelStore.isRuntimeSupported(model) else {
                            return .unsupportedRecognitionModel(model.title)
                        }
                        guard hasImportedAudio else {
                            return .importedAudioRequired(model.title)
                        }
                    } else if !RecognitionModelStore.isSelectable(model) {
                        return .unsupportedRecognitionModel(model.title)
                    }
                }
                do {
                    _ = try RealtimePipelineCoordinator.validated(
                        configurations,
                        physicalMemory: physicalMemory
                    )
                    return nil
                } catch let error as RealtimePipelineError {
                    return RealtimeStartBlocker(error)
                } catch {
                    return nil
                }
            }

            nonisolated static func shouldSerializeMOSS(
                configurations: [RealtimeLaneConfiguration],
                physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
            ) -> Bool {
                guard physicalMemory < 24 * 1024 * 1024 * 1024 else { return false }
                return configurations.contains { $0.recognitionModel.runtime == .mossOffline } &&
                    configurations.contains { $0.recognitionModel.runtime == .fluidAudio }
            }

            public func setImportedAudioURL(_ url: URL?) {
                guard !isRealtimeSessionBusy else { return }
                importedAudioURL = url
                if url == nil {
                    restorePreMOSSRecognitionModels()
                }
                statusText = String(localized: "Ready")
            }

            public func addDefaultLane() async throws {
                let recognitionModelID = preferences.realtimeRecognitionModelID
                guard let translationProvider = RealtimeTranslationProvider.availableCases.first(where: { provider in
                    !laneConfigurations.contains {
                        $0.recognitionModelID == recognitionModelID &&
                            $0.translationProvider == provider
                    }
                }) else {
                    throw RealtimePipelineError.duplicateLane
                }
                try await addLane(
                    recognitionModelID: recognitionModelID,
                    translationProvider: translationProvider
                )
            }

            public func addLane(
                recognitionModelID: String,
                translationProvider: RealtimeTranslationProvider
            ) async throws {
                guard laneConfigurations.count < RealtimePipelineCoordinator.maximumLaneCount else {
                    throw RealtimePipelineError.maximumLaneCount
                }
                guard !isRealtimeMemoryConstrained else {
                    throw RealtimePipelineError.memoryPressure
                }
                let model = RecognitionModelStore.selectableDescriptor(forModelID: recognitionModelID)
                guard model.runtime != .mossOffline || hasImportedAudio else {
                    throw RealtimeRecognizerError.unsupportedModel(model.id)
                }
                guard !laneConfigurations.contains(where: {
                    $0.recognitionModelID == model.id &&
                        $0.translationProvider == translationProvider
                }) else {
                    throw RealtimePipelineError.duplicateLane
                }
                guard model.supports(sourceLanguage: preferences.realtimeSourceLanguage) else {
                    throw RealtimeRecognizerError.unsupportedModel(model.id)
                }
                guard await RecognitionModelStore.shared.isModelCached(model) else {
                    throw RealtimePipelineError.modelNotDownloaded(model.title)
                }
                let configuration = RealtimeLaneConfiguration(
                    recognitionModelID: model.id,
                    translationProvider: translationProvider
                )
                _ = try RealtimePipelineCoordinator.validated(laneConfigurations + [configuration])
                if isRunning {
                    try await ensureAppleTranslateLanguagesInstalledIfNeeded(providers: [translationProvider])
                    try await realtimePipelineCoordinator.addLane(configuration)
                }
                laneConfigurations.append(configuration)
                laneSnapshots.append(RealtimeLaneSnapshot(
                    configuration: configuration,
                    phase: isRunning ? .loading : .ready
                ))
                if isRunning {
                    applyLaneSnapshots(realtimePipelineCoordinator.snapshots)
                }
                persistLaneConfiguration()
            }

            public func removeLane(id: UUID) async {
                guard laneConfigurations.count > 1 else { return }
                if isRunning {
                    await realtimePipelineCoordinator.removeLane(id: id)
                }
                laneConfigurations.removeAll { $0.id == id }
                laneSnapshots.removeAll { $0.id == id }
                if primaryLaneID == id, let first = laneConfigurations.first {
                    primaryLaneID = first.id
                    realtimePipelineCoordinator.setPrimaryLaneID(first.id)
                }
                persistLaneConfiguration()
                projectPrimaryLane()
            }

            public func setPrimaryLane(id: UUID) {
                guard laneConfigurations.contains(where: { $0.id == id }) else { return }
                primaryLaneID = id
                realtimePipelineCoordinator.setPrimaryLaneID(id)
                if let configuration = primaryLaneConfiguration {
                    if configuration.recognitionModel.runtime != .mossOffline {
                        preferences.setRealtimeRecognitionModelID(configuration.recognitionModelID)
                    }
                    preferences.setRealtimeTranslationProvider(configuration.translationProvider)
                }
                persistLaneConfiguration()
                projectPrimaryLane()
            }

            public func updateLane(
                id: UUID,
                recognitionModelID: String,
                translationProvider: RealtimeTranslationProvider
            ) {
                guard !isRealtimeSessionBusy,
                      let index = laneConfigurations.firstIndex(where: { $0.id == id })
                else {
                    return
                }
                let model = RecognitionModelStore.selectableDescriptor(forModelID: recognitionModelID)
                guard model.runtime != .mossOffline || hasImportedAudio else { return }
                guard model.supports(sourceLanguage: preferences.realtimeSourceLanguage) else { return }
                let duplicate = laneConfigurations.contains {
                    $0.id != id &&
                        $0.recognitionModelID == model.id &&
                        $0.translationProvider == translationProvider
                }
                guard !duplicate else { return }
                let previousModelID = laneConfigurations[index].recognitionModelID
                if model.runtime == .mossOffline,
                   previousModelID != model.id
                {
                    preMOSSRecognitionModelIDs[id] = previousModelID
                } else if model.runtime != .mossOffline {
                    preMOSSRecognitionModelIDs[id] = nil
                }
                laneConfigurations[index].recognitionModelID = model.id
                laneConfigurations[index].translationProvider = translationProvider
                laneSnapshots[index] = RealtimeLaneSnapshot(configuration: laneConfigurations[index])
                if id == primaryLaneID {
                    if model.runtime != .mossOffline {
                        preferences.setRealtimeRecognitionModelID(model.id)
                    }
                    preferences.setRealtimeTranslationProvider(translationProvider)
                }
                persistLaneConfiguration()
                projectPrimaryLane()
            }

            private var isRealtimeSessionBusy: Bool {
                isRunning || isStarting || isStopping
            }

            private func persistLaneConfiguration() {
                let persistentConfigurations = laneConfigurations.map { configuration in
                    guard configuration.recognitionModel.runtime == .mossOffline else {
                        return configuration
                    }
                    var restored = configuration
                    restored.recognitionModelID =
                        preMOSSRecognitionModelIDs[configuration.id] ??
                        RecognitionModelDescriptor.appleSpeech.id
                    return restored
                }
                RealtimeLaneConfigurationPersistence.save(
                    configurations: persistentConfigurations,
                    primaryLaneID: primaryLaneID,
                    defaults: .standard
                )
            }

            private func restorePreMOSSRecognitionModels() {
                guard !preMOSSRecognitionModelIDs.isEmpty else { return }
                for index in laneConfigurations.indices {
                    guard laneConfigurations[index].recognitionModel.runtime == .mossOffline else { continue }
                    laneConfigurations[index].recognitionModelID =
                        preMOSSRecognitionModelIDs[laneConfigurations[index].id] ??
                        RecognitionModelDescriptor.appleSpeech.id
                    laneSnapshots[index].configuration = laneConfigurations[index]
                }
                preMOSSRecognitionModelIDs.removeAll()
                persistLaneConfiguration()
                projectPrimaryLane()
            }

            private func applyLaneSnapshots(_ snapshots: [RealtimeLaneSnapshot]) {
                var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
                laneSnapshots = laneConfigurations.compactMap { configuration in
                    snapshotsByID.removeValue(forKey: configuration.id) ??
                        laneSnapshots.first(where: { $0.id == configuration.id }) ??
                        RealtimeLaneSnapshot(configuration: configuration)
                }
                projectPrimaryLane()
                autosaveRealtimeHistoryIfNeeded()
            }

            private func projectPrimaryLane() {
                guard let lane = laneSnapshots.first(where: { $0.id == primaryLaneID }) ?? laneSnapshots.first else {
                    return
                }
                assignIfChanged(&sourceText, lane.sourceText)
                assignIfChanged(&translatedText, lane.translatedText)
                assignIfChanged(&pendingSourceText, lane.pendingSourceText)
                assignIfChanged(&pendingTranslatedText, lane.pendingTranslatedText)
                assignIfChanged(&sentencePairs, lane.sentencePairs)
                assignIfChanged(&captionLines, lane.captionLines)
                translationSourceText = lane.sentencePairs.map(\.original).joined(separator: "\n\n")
                presentationSourceSegments = lane.sentencePairs.map(\.original)
                historySessionBuilder.sync(
                    pairs: realtimeHistoryPairs(),
                    at: Date()
                )
                if isRunning {
                    statusText = lane.phase == .paused
                        ? String(localized: "Paused")
                        : String(localized: "Listening to \(inputSource.title)")
                }
            }

            func applyLaneSnapshotFixture(
                _ snapshots: [RealtimeLaneSnapshot],
                primaryLaneID: UUID
            ) {
                laneConfigurations = snapshots.map(\.configuration)
                laneSnapshots = snapshots
                self.primaryLaneID = primaryLaneID
                projectPrimaryLane()
            }
        #endif

        public func start() async {
            logRealtime(
                """
                start requested input=\(inputSource.rawValue) provider=\(preferences.realtimeTranslationProvider.rawValue) \
                engine=\(preferences.realtimeRecognitionEngine.rawValue) source=\(preferences.realtimeSourceLanguage.rawValue) \
                target=\(preferences.realtimeTargetLanguage.rawValue) showCaptions=\(showCaptions)
                """
            )
            guard !isRunning else {
                logRealtime("start ignored reason=alreadyRunning input=\(inputSource.rawValue)")
                return
            }
            guard !isStarting else {
                logRealtime("start ignored reason=alreadyStarting input=\(inputSource.rawValue)")
                return
            }
            guard hasRequiredLanguageSelection else {
                errorMessage = nil
                startFailureAlert = nil
                statusText = preferences.realtimeTranslationProvider.performsTranslation
                    ? String(localized: "Choose source and target languages to start")
                    : String(localized: "Choose source language to start")
                logRealtime("start blocked reason=missingLanguage status=\(statusText)")
                return
            }
            let sessionID = UUID()
            activeSessionID = sessionID
            drainingSessionID = nil
            #if os(macOS)
                isImportedAudioSession = importedAudioURL != nil
            #endif
            isStarting = true
            defer {
                isStarting = false
            }

            #if os(iOS)
                if inputSource == .iphoneAudio {
                    await startIPhoneAudioBroadcastSession()
                    return
                }
            #endif

            do {
                try await ensureAppleTranslateLanguagesInstalledIfNeeded()
            } catch {
                guard shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
                handleStartFailure(error)
                return
            }
            guard shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }

            resetTranscript()
            isPaused = false
            errorMessage = nil
            startFailureAlert = nil

            do {
                #if os(macOS)
                    if importedAudioURL == nil {
                        try await startLiveCaptureBeforeRecognition()
                    }
                #endif
                let audioSampleRate = try await startRecognition(sessionID: sessionID)
                #if os(macOS)
                    if importedAudioURL != nil {
                        startRealtimeHistorySessionIfNeeded()
                    }
                #else
                    startRealtimeHistorySessionIfNeeded()
                #endif
                guard shouldAcceptRealtimeCallback(sessionID: sessionID) else {
                    await stop()
                    return
                }
                #if os(macOS)
                    if let importedAudioURL {
                        isRunning = true
                        statusText = String(localized: "Recognizing speech")
                        startImportedAudioTask(url: importedAudioURL, sessionID: sessionID)
                        return
                    }
                #endif
                #if os(iOS)
                    statusText = String(localized: "Starting \(inputSource.title)...")
                    switch inputSource {
                    case .microphone:
                        try await microphoneAudioCapture.start(
                            sampleRate: audioSampleRate,
                            allowsPlayback: false
                        )
                    case .iphoneAudio:
                        throw RealtimeIPhoneAudioPreflightFailure.appleTranslateUnavailable
                    }
                #endif
                guard shouldAcceptRealtimeCallback(sessionID: sessionID) else {
                    await stop()
                    return
                }
                isRunning = true
                statusText = String(localized: "Listening to \(inputSource.title)")
                logRealtime("start succeeded input=\(inputSource.rawValue) sampleRate=\(audioSampleRate)")
            } catch {
                guard shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
                await stop()
                logRealtime("start failed error=\(Self.describe(error))")
                handleStartFailure(error)
            }
        }

        public func stop() async {
            guard !isStopping else {
                logRealtime("stop ignored reason=alreadyStopping input=\(inputSource.rawValue)")
                return
            }
            isStopping = true
            drainingSessionID = activeSessionID
            #if os(macOS)
                importedAudioTask?.cancel()
                importedAudioTask = nil
            #endif
            defer {
                isStopping = false
            }

            statusText = String(localized: "Stopping capture")
            logRealtime(
                """
                stop requested input=\(inputSource.rawValue) running=\(isRunning) sourceLen=\(sourceText.count) \
                stableLen=\(translationSourceText.count) pendingLen=\(pendingSourceText.count) pairs=\(sentencePairs.count)
                """
            )
            #if os(iOS)
                if inputSource == .iphoneAudio {
                    saveRealtimeHistoryIfPossible()
                    guard let broadcastStateStore else {
                        finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                        return
                    }
                    // Capture the phase before requestStop() overwrites it with .stopping.
                    let priorPhase = broadcastStateStore.load()?.phase
                    broadcastStateStore.requestStop()
                    isPaused = false
                    audioLevel = nil
                    // When the broadcast upload extension never started, no heartbeat
                    // will consume stopRequested, so finish immediately instead of
                    // waiting for the state to go stale.
                    if priorPhase == nil || priorPhase == .idle || priorPhase == .waiting {
                        finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                    } else {
                        statusText = String(localized: "Stopping iPhone Audio")
                        await waitForIPhoneAudioBroadcastStop()
                        if isRunning {
                            finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                        }
                    }
                    return
                }
            #endif

            statusText = String(localized: "Processing final text")
            #if os(macOS)
                await systemAudioCapture.stop()
                await secondarySystemAudioCapture.stop()
            #endif
            microphoneAudioCapture.stop()
            #if os(macOS)
                secondaryMicrophoneAudioCapture.stop()
                secondaryAudioSource = nil
            #endif
            #if os(macOS)
                await realtimePipelineCoordinator.stop()
                realtimePipelineAudioFanout.resetTimeline()
            #else
                await activeRecognizer.stop()
            #endif
            await callbackDrain.wait()
            activeSessionID = UUID()
            drainingSessionID = nil
            finalizePendingRecognition()
            let partialTask = partialTranslationTask
            cancelPartialTranslationWork()
            await partialTask?.value
            let finalTask = finalTranslationTask
            await finalTask?.value
            audioHistoryRecorder.finish()
            secondaryAudioHistoryRecorder.finish()
            statusText = String(localized: "Saving realtime history")
            saveRealtimeHistoryIfPossible(generateTitle: true)
            isRunning = false
            isPaused = false
            audioLevel = nil
            audioSampleCount = 0
            statusText = sourceText.isEmpty ? String(localized: "Ready") : String(localized: "Stopped")
            #if os(macOS)
                if isImportedAudioSession {
                    isImportedAudioSession = false
                    importedAudioURL = nil
                    restorePreMOSSRecognitionModels()
                }
            #endif
            logRealtime("stop completed status=\(statusText) savedSourceLen=\(sourceText.count)")
        }

        public func toggleRunning() async {
            if isRunning {
                await stop()
            } else {
                await start()
            }
        }

        public func dismissStartFailureAlert() {
            startFailureAlert = nil
        }

        public func cycleCaptionDisplayMode() {
            captionDisplayMode = captionDisplayMode.next
        }

        public func togglePaused() {
            guard isRunning else { return }
            #if os(macOS)
                guard canPauseCurrentSession else { return }
            #endif
            #if os(iOS)
                guard inputSource != .iphoneAudio else { return }
            #endif
            let isTranslating = finalTranslationTask != nil || partialTranslationTask != nil
            isPaused.toggle()
            if usesRealtimeSessionHistory {
                if isPaused {
                    historySessionBuilder.pause()
                    audioHistoryRecorder.pause()
                    secondaryAudioHistoryRecorder.pause()
                } else {
                    historySessionBuilder.resume()
                    audioHistoryRecorder.resume()
                    secondaryAudioHistoryRecorder.resume()
                }
            }
            activeRecognizer.setPaused(isPaused)
            #if os(macOS)
                realtimePipelineCoordinator.setPaused(isPaused)
            #endif
            statusText = isPaused ? String(localized: "Paused") : String(localized: "Listening to \(inputSource.title)")
            logRealtime("pause toggled paused=\(isPaused) translating=\(isTranslating) status=\(statusText)")
            if isPaused, !isTranslating {
                saveRealtimeHistoryIfPossible()
            }
        }

        public func pause() {
            guard isRunning, !isPaused else { return }
            togglePaused()
        }

        public func resetTranscript() {
            logRealtime(
                """
                resetTranscript sourceLen=\(sourceText.count) stableLen=\(translationSourceText.count) \
                pendingLen=\(pendingSourceText.count) translatedLen=\(translatedText.count) pairs=\(sentencePairs.count)
                """
            )
            cancelTranslationWork()
            captionClearAnchor = .empty
            transcriptAccumulator.reset()
            translationState.reset()
            #if os(macOS)
                realtimePipelineCoordinator.reset()
                laneSnapshots = laneConfigurations.map {
                    RealtimeLaneSnapshot(configuration: $0)
                }
            #endif
            presentationSourceSegments = []
            historyCheckpoint.reset()
            historySessionBuilder.reset()
            audioHistoryRecorder.reset()
            secondaryAudioHistoryRecorder.reset()
            #if os(macOS)
                secondaryAudioSource = nil
            #endif
            resetRealtimeHistoryAutosave()
            #if os(iOS)
                latestBroadcastRealtimeHistorySession = nil
            #endif
            if !sourceText.isEmpty {
                sourceText = ""
            }
            syncTranslationStatePresentation()
            errorMessage = nil
            if !isRunning {
                statusText = String(localized: "Ready")
            } else {
                startRealtimeHistorySessionIfNeeded()
            }
        }

        public func clearTranscriptDisplay() {
            captionClearAnchor = RealtimeCaptionDisplayClearAnchor(lines: resolvedCaptionLines())
            assignIfChanged(&captionLines, [])
        }

        public func endSession() async {
            await stop()
            resetTranscript()
        }

        public func applySnapshotFixture(_ fixture: SnapshotRealtimeBilingualLiveFixture) {
            cancelTranslationWork()
            inputSource = .microphone
            preferences.setRealtimeTranslationProvider(fixture.translationProvider)
            captionDisplayMode = fixture.captionDisplayMode
            isRunning = true
            isPaused = false
            sourceText = fixture.sourceText
            translatedText = fixture.translatedText
            translationSourceText = fixture.sourceText
            sentencePairs = fixture.sentencePairs
            pendingSourceText = fixture.pendingSource
            pendingTranslatedText = fixture.pendingTranslation
            presentationSourceSegments = RealtimeTranscriptSegmenter.segments(from: translationSourceText)
            refreshCaptionLines(event: "snapshotFixture")
            statusText = String(localized: "Listening to \(inputSource.title)")
            errorMessage = nil
            startFailureAlert = nil
            audioLevel = -22
            audioSampleCount = 1240
            preferences.setRealtimeSourceLanguage(fixture.sourceLanguage, reason: "Snapshot fixture")
            preferences.setRealtimeTargetLanguage(fixture.targetLanguage, reason: "Snapshot fixture")
            preferences.setRealtimeRecognitionEngine(.appleSpeech)
            #if os(macOS)
                let configuration = RealtimeLaneConfiguration(
                    recognitionModelID: RecognitionModelDescriptor.appleSpeech.id,
                    translationProvider: fixture.translationProvider
                )
                laneConfigurations = [configuration]
                primaryLaneID = configuration.id
                laneSnapshots = [
                    RealtimeLaneSnapshot(
                        configuration: configuration,
                        phase: .recognizing,
                        sourceText: fixture.sourceText,
                        translatedText: fixture.translatedText,
                        pendingSourceText: fixture.pendingSource,
                        pendingTranslatedText: fixture.pendingTranslation,
                        sentencePairs: fixture.sentencePairs,
                        captionLines: captionLines
                    ),
                ]
            #endif
        }

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

        private func speechLocale() -> Locale {
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
            private func registerForegroundOnlyLifecycle() {
                foregroundOnlyObservers = [
                    NotificationCenter.default.addObserver(
                        forName: UIApplication.didEnterBackgroundNotification,
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            await self?.stopForForegroundOnlyLifecycle()
                        }
                    },
                    NotificationCenter.default.addObserver(
                        forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            await self?.stopForForegroundOnlyLifecycle()
                        }
                    },
                    NotificationCenter.default.addObserver(
                        forName: AVAudioSession.interruptionNotification,
                        object: nil,
                        queue: .main
                    ) { [weak self] notification in
                        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                              type == .began
                        else {
                            return
                        }
                        Task { @MainActor in
                            await self?.stopForForegroundOnlyLifecycle()
                        }
                    },
                ]
            }

            private func stopForForegroundOnlyLifecycle() async {
                guard isRunning else { return }
                guard inputSource != .iphoneAudio else { return }
                await stop()
                statusText = String(localized: "Stopped")
            }

            private func startIPhoneAudioBroadcastSession() async {
                logRealtime(
                    """
                    iphoneBroadcast start requested source=\(preferences.realtimeSourceLanguage.rawValue) \
                    target=\(preferences.realtimeTargetLanguage.rawValue)
                    """
                )
                if let failure = await RealtimeIPhoneAudioPreflight.evaluate(
                    sourceLanguage: preferences.realtimeSourceLanguage,
                    targetLanguage: preferences.realtimeTargetLanguage
                ) {
                    logRealtime("iphoneBroadcast preflightFailed error=\(Self.describe(failure))")
                    handleStartFailure(failure)
                    return
                }

                resetTranscript()
                isPaused = false
                errorMessage = nil
                startFailureAlert = nil
                audioLevel = nil
                audioSampleCount = 0

                let sessionID = UUID().uuidString
                broadcastStateStore?.reset(sessionID: sessionID, phase: .waiting)
                isRunning = true
                statusText = String(localized: "Waiting for iPhone Audio broadcast")
                lastBroadcastStateLogSignature = nil
                logRealtime("iphoneBroadcast waiting session=\(sessionID)")
                startBroadcastStatePolling(sessionID: sessionID)
            }

            private func startBroadcastStatePolling(sessionID: String) {
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

            private func stopBroadcastStatePolling() {
                broadcastStatePollingTask?.cancel()
                broadcastStatePollingTask = nil
            }

            private func waitForIPhoneAudioBroadcastStop() async {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while isRunning, inputSource == .iphoneAudio, ContinuousClock.now < deadline {
                    if let state = broadcastStateStore?.load() {
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

            private func pollBroadcastState(sessionID: String) {
                guard isRunning, inputSource == .iphoneAudio else {
                    stopBroadcastStatePolling()
                    return
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
                        finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                    }
                    return
                }

                applyBroadcastState(state)
            }

            private func applyBroadcastState(_ state: RealtimeBroadcastState) {
                sourceText = state.sourceText
                translationSourceText = state.translationSourceText
                presentationSourceSegments = state.sourceSegments.isEmpty
                    ? RealtimeTranscriptSegmenter.segments(from: state.translationSourceText)
                    : state.sourceSegments
                pendingSourceText = state.pendingSourceText
                translatedText = state.translatedText
                pendingTranslatedText = state.pendingTranslatedText
                sentencePairs = state.sentencePairs
                audioSampleCount = state.audioSampleCount
                audioLevel = state.audioLevel
                errorMessage = state.errorMessage
                latestBroadcastRealtimeHistorySession = state.realtimeHistorySession
                autosaveRealtimeHistoryIfNeeded()
                refreshCaptionLines(event: "broadcastState")
                logBroadcastStateIfNeeded(state)

                if state.isStale() {
                    if state.stopRequested || state.phase == .stopping {
                        finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                    } else if Self.isStaleActiveIPhoneAudioBroadcast(state) {
                        let alert = Self.iPhoneAudioBroadcastFailureAlert(for: state)
                        finishIPhoneAudioBroadcastSession(status: String(localized: "Error"))
                        handleErrorMessage(alert.message)
                        startFailureAlert = alert
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
                    finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                case .failed:
                    let alert = Self.iPhoneAudioBroadcastFailureAlert(for: state)
                    finishIPhoneAudioBroadcastSession(status: String(localized: "Error"))
                    handleErrorMessage(alert.message)
                    startFailureAlert = alert
                }
            }

            private func finishIPhoneAudioBroadcastSession(status: String) {
                saveRealtimeHistoryIfPossible(generateTitle: true)
                stopBroadcastStatePolling()
                isRunning = false
                isStopping = false
                activeSessionID = UUID()
                drainingSessionID = nil
                isPaused = false
                audioLevel = nil
                audioSampleCount = 0
                statusText = status
                logRealtime("iphoneBroadcast finished status=\(status)")
            }
        #endif

        private func startRecognition(sessionID: UUID) async throws -> Int {
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
                    statusText = String(localized: "Preparing speech recognition...")
                    switch model.runtime {
                    case .appleSpeech:
                        try await transcriber.start(model: model, locale: speechLocale(), sessionID: sessionID)
                        activeRecognizer.set(transcriber)
                        return transcriber.sampleRate
                    case .fluidAudio:
                        #if os(macOS) && arch(arm64) && canImport(FluidAudio)
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

        #if os(macOS)
            private func startLiveCaptureBeforeRecognition() async throws {
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

            private func startImportedAudioTask(url: URL, sessionID: UUID) {
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

            private func finishImportedAudioIfCurrent(sessionID: UUID) async {
                guard shouldAcceptRealtimeCallback(sessionID: sessionID),
                      isImportedAudioSession
                else {
                    return
                }
                importedAudioTask = nil
                await stop()
            }

            private func handleImportedAudioFailure(_ error: Error, sessionID: UUID) async {
                guard shouldAcceptRealtimeCallback(sessionID: sessionID) else { return }
                importedAudioTask = nil
                await stop()
                handleStartFailure(error)
            }

            private func startSecondaryAudioRecordingIfNeeded(sampleRate: Int) async {
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

            private func handleSecondaryAudioFailure(_ error: Error, source: RealtimeAudioInputSource) async {
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

        private func ensureAppleTranslateLanguagesInstalledIfNeeded(
            providers requestedProviders: Set<RealtimeTranslationProvider>? = nil
        ) async throws {
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

            guard #available(iOS 17.4, macOS 14.4, *) else {
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
                let status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                    source: source,
                    target: target,
                    strategy: strategy
                )
                if let error = Self.appleTranslateLanguagePreflightFailure(
                    status: status,
                    languagePair: languagePair
                ) {
                    throw error
                }
            }
        }

        private func handleRecognized(_ result: RealtimeRecognitionResult) {
            let previousStableLength = translationSourceText.count
            let previousPendingLength = pendingSourceText.count
            let previousPairCount = sentencePairs.count
            let previousTranslatedLength = translatedText.count
            let recognizedSourceText = transcriptAccumulator.append(result, afterLongSilence: false)
            if sourceText != recognizedSourceText {
                sourceText = recognizedSourceText
            }
            updateTranscriptPresentation()
            let sourceLength = sourceText.count
            let sourcePreview = Self.preview(sourceText)
            logRealtime(
                """
                recognized state=\(String(describing: result.state)) \
                confidence=\(result.confidence) \
                inputLen=\(result.text.count) sourceLen=\(sourceLength) \
                stableLen \(previousStableLength)->\(translationSourceText.count) \
                pendingLen \(previousPendingLength)->\(pendingSourceText.count) \
                translatedLen \(previousTranslatedLength)->\(translatedText.count) \
                pairs \(previousPairCount)->\(sentencePairs.count) visible=\(sourcePreview)
                """
            )
            statusText = result
                .confidence > 0 ? String(localized: "Recognizing") : String(localized: "Listening to \(inputSource.title)")
            scheduleTranslation()
        }

        private func finalizePendingRecognition() {
            let pending = transcriptAccumulator.pendingSentenceText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pending.isEmpty else { return }

            assignIfChanged(&sourceText, transcriptAccumulator.commitPartial())
            updateTranscriptPresentation()
            scheduleTranslation()
        }

        private func updateAudioSampleCount(_ count: Int, level: Float?) {
            audioSampleCount = count
            audioLevel = level
        }

        private func scheduleTranslation() {
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
                let sourceLength = sourceText.count
                let translatedLength = translatedText.count
                let pairCount = sentencePairs.count
                logRealtime(
                    """
                    scheduleTranslation noRequest provider=\(provider.rawValue) \
                    sourceLen=\(sourceLength) translatedLen=\(translatedLength) pairs=\(pairCount)
                    """
                )
                cancelTranslationWork()
                translationState.clearStableTranslation()
                syncTranslationStatePresentation()
                logPresentation("scheduleTranslation clearedEmptySource")
                return
            }

            let translatedLength = translatedText.count
            let pairCount = sentencePairs.count
            let translationPreview = Self.preview(partialSourceText.isEmpty ? stableSourceText : partialSourceText)
            logRealtime(
                """
                scheduleTranslation request provider=\(provider.rawValue) \
                finalLen=\(stableSourceText.count) partialLen=\(partialSourceText.count) \
                translatedLen=\(translatedLength) pairs=\(pairCount) text=\(translationPreview)
                """
            )

            guard hasRequiredLanguageSelection else {
                logRealtime("scheduleTranslation missingLanguage clearsTranslation=true")
                cancelTranslationWork()
                translationState.resetTranslationResults()
                syncTranslationStatePresentation()
                logPresentation("scheduleTranslation clearedMissingLanguage")
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
                logRealtime("scheduleTranslation sameLanguage provider=\(provider.rawValue)")
                cancelTranslationWork()
                translationState.applySameLanguageTranslation()
                syncTranslationStatePresentation()
                logPresentation("scheduleTranslation appliedSameLanguage")
                statusText = String(localized: "Source and target are the same (\(languagePair))")
                return
            }

            if stableSourceText.isEmpty {
                logRealtime("scheduleTranslation clearStable reason=emptyStable partialLen=\(partialSourceText.count)")
                translationState.clearStableTranslation()
                syncTranslationStatePresentation()
                logPresentation("scheduleTranslation stableEmpty")
            } else {
                let oldPairCount = translationState.sentencePairs.count
                let oldTranslatedLength = translationState.translatedText.count
                translationState.updateCachedSentencePairs(
                    provider: provider,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetOption
                )
                logRealtime(
                    """
                    scheduleTranslation cacheRefresh stableLen=\(stableSourceText.count) \
                    pairs \(oldPairCount)->\(translationState.sentencePairs.count) \
                    translatedLen \(oldTranslatedLength)->\(translationState.translatedText.count)
                    """
                )
                syncTranslationStatePresentation()
                logPresentation("scheduleTranslation cacheRefreshSynced")
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

        private func processFinalTranslationRequests() async {
            while !Task.isCancelled {
                guard !queuedFinalTranslationRequests.isEmpty else {
                    logRealtime("finalTranslationTask drained")
                    finalTranslationTask = nil
                    updateStatusAfterTranslationActivity()
                    if isPaused {
                        saveRealtimeHistoryIfPossible()
                    }
                    return
                }
                let request = queuedFinalTranslationRequests.removeFirst()
                logRealtime(
                    """
                    finalTranslationTask dequeued remaining=\(queuedFinalTranslationRequests.count) \
                    requestLen=\(request.translationText.count) text=\(Self.preview(request.translationText))
                    """
                )

                do {
                    guard !Task.isCancelled else { return }
                    let result = try await RealtimeTranslationService.translate(request)
                    guard !Task.isCancelled else { return }
                    applyFinalTranslationResult(result, request: request)
                    if !queuedFinalTranslationRequests.isEmpty {
                        logRealtime(
                            """
                            finalTranslationTask sleep cadence=\(request.cadenceInterval) \
                            queued=\(queuedFinalTranslationRequests.count)
                            """
                        )
                        try await Task.sleep(for: .milliseconds(Int((request.cadenceInterval * 1000).rounded(.up))))
                    }
                } catch is CancellationError {
                    logRealtime("finalTranslationTask cancelled")
                    finalTranslationTask = nil
                    return
                } catch {
                    translationState.finishFinalTranslationRequest(request)
                    syncTranslationStatePresentation()
                    let message = Self.translationErrorMessage(
                        error,
                        source: request.source,
                        target: request.targetLanguage,
                        provider: request.provider
                    )
                    logRealtime("finalTranslationTask error=\(message)")
                    handleErrorMessage(message)
                }
            }
        }

        private func processPartialTranslationRequests() async {
            while !Task.isCancelled {
                guard var request = latestPartialTranslationRequest else {
                    logRealtime("partialTranslationTask drained")
                    partialTranslationTask = nil
                    nextPartialTranslationAllowedAt = nil
                    updateStatusAfterTranslationActivity()
                    return
                }
                latestPartialTranslationRequest = nil
                logRealtime(
                    """
                    partialTranslationTask dequeued requestLen=\(request.translationText.count) \
                    text=\(Self.preview(request.translationText))
                    """
                )

                do {
                    let allowedAt = nextPartialTranslationAllowedAt ?? Date().addingTimeInterval(request.cadenceInterval)
                    nextPartialTranslationAllowedAt = allowedAt
                    let delay = allowedAt.timeIntervalSinceNow
                    if delay > 0 {
                        logRealtime("partialTranslationTask sleep delay=\(delay) cadence=\(request.cadenceInterval)")
                        try await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
                    }

                    if let newerRequest = latestPartialTranslationRequest {
                        logRealtime(
                            """
                            partialTranslationTask replacedWithNewer oldLen=\(request.translationText.count) \
                            newLen=\(newerRequest.translationText.count)
                            """
                        )
                        request = newerRequest
                        latestPartialTranslationRequest = nil
                    }

                    guard !Task.isCancelled else { return }
                    nextPartialTranslationAllowedAt = Date().addingTimeInterval(request.cadenceInterval)
                    let result = try await RealtimeTranslationService.translate(request)
                    guard !Task.isCancelled else { return }
                    applyPartialTranslationResult(result, request: request)
                } catch is CancellationError {
                    partialTranslationTask = nil
                    return
                } catch {
                    let message = Self.translationErrorMessage(
                        error,
                        source: request.source,
                        target: request.targetLanguage,
                        provider: request.provider
                    )
                    logRealtime("partialTranslationTask error=\(message)")
                    handleErrorMessage(message)
                }
            }
        }

        private func saveRealtimeHistoryIfPossible(generateTitle: Bool = false) {
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

        private func autosaveRealtimeHistoryIfNeeded(now: Date = Date()) {
            guard isRunning, let session = currentRealtimeHistorySession() else { return }
            guard session.segments != lastRealtimeHistoryAutosaveSegments ||
                session.audioRecordings != lastRealtimeHistoryAutosaveRecordings ||
                session.tracks != lastRealtimeHistoryAutosaveTracks
            else {
                return
            }

            if let lastRealtimeHistoryAutosaveAt {
                let delay = Self.realtimeHistoryAutosaveInterval - now.timeIntervalSince(lastRealtimeHistoryAutosaveAt)
                if delay > 0 {
                    scheduleRealtimeHistoryAutosave(after: delay)
                    return
                }
            }

            _ = saveRealtimeHistorySession(session, at: now, event: "autosaved")
        }

        private func scheduleRealtimeHistoryAutosave(after delay: TimeInterval) {
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

        private func saveRealtimeHistorySession(
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
                logRealtime("history session \(event) input=\(inputSource.rawValue) segments=\(session.segments.count)")
                return true
            } catch {
                logRealtime("history session save failed event=\(event) error=\(Self.describe(error))")
                return false
            }
        }

        private func generateRealtimeHistoryTitleIfNeeded(for session: RealtimeHistorySession) {
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

        private func currentRealtimeHistorySession() -> RealtimeHistorySession? {
            #if os(iOS)
                if inputSource == .iphoneAudio {
                    guard preferences.realtimeTranslationProvider == .appleTranslator else { return nil }
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

        private func historyInputSourceID(for inputSource: RealtimeAudioInputSource) -> RealtimeHistoryInputSource {
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

        private func resetRealtimeHistoryAutosave() {
            realtimeHistoryAutosaveTask?.cancel()
            realtimeHistoryAutosaveTask = nil
            lastRealtimeHistoryAutosaveAt = nil
            lastRealtimeHistoryAutosaveSegments = nil
            lastRealtimeHistoryAutosaveRecordings = nil
            lastRealtimeHistoryAutosaveTracks = nil
        }

        private var usesRealtimeSessionHistory: Bool {
            #if os(macOS)
                return !laneConfigurations.isEmpty
            #else
                return preferences.realtimeTranslationProvider.usesAppleTextTranslation
            #endif
        }

        private func startRealtimeHistorySessionIfNeeded() {
            resetRealtimeHistoryAutosave()
            if usesRealtimeSessionHistory {
                historySessionBuilder.start()
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

        private func audioHistoryRecordingsSnapshot() -> [RealtimeHistoryAudioRecording] {
            [
                audioHistoryRecorder.snapshot(),
                secondaryAudioHistoryRecorder.snapshot(),
            ]
            .compactMap { $0 }
            .sorted { $0.source.rawValue < $1.source.rawValue }
        }

        private func historyAudioSource(for inputSource: RealtimeAudioInputSource) -> RealtimeHistoryAudioSource {
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

        private var activeHistoryAudioSource: RealtimeHistoryAudioSource {
            #if os(macOS)
                isImportedAudioSession ? .importedAudio : historyAudioSource(for: inputSource)
            #else
                historyAudioSource(for: inputSource)
            #endif
        }

        private var activeHistoryInputSourceID: RealtimeHistoryInputSource {
            #if os(macOS)
                isImportedAudioSession ? .importedAudio : historyInputSourceID(for: inputSource)
            #else
                historyInputSourceID(for: inputSource)
            #endif
        }

        #if os(macOS)
            private var secondaryHistoryInputSource: RealtimeAudioInputSource? {
                guard !isImportedAudioSession else { return nil }
                guard preferences.realtimeDualInputHistoryRecordingEnabled else { return nil }
                switch inputSource {
                case .macAudio:
                    return .microphone
                case .microphone:
                    return .macAudio
                }
            }
        #endif

        private func syncRealtimeHistorySession() {
            guard usesRealtimeSessionHistory else { return }
            historySessionBuilder.sync(pairs: realtimeHistoryPairs())
        }

        private func realtimeHistoryPairs() -> [SentencePair] {
            return Self.historyPairs(
                sentencePairs: sentencePairs,
                pendingSourceText: pendingSourceText,
                pendingTranslatedText: pendingTranslatedText,
                sourceText: sourceText,
                translatedText: translatedText
            )
        }

        private func handleErrorMessage(_ message: String) {
            logRealtime("errorMessage \(message)")
            errorMessage = message
            statusText = String(localized: "Error")
        }

        private func handleStartFailure(_ error: Error) {
            handleErrorMessage(Self.describe(error))
            startFailureAlert = Self.startFailureAlert(for: error)
        }

        private func handleRuntimeFailure(_ error: Error, context: String) async {
            guard !Self.isCancellationError(error) else { return }
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
                case .broadcasting, .recognizing, .translating, .paused, .failed:
                    return true
                case .idle, .waiting, .stopping, .stopped:
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

            private nonisolated static func iPhoneAudioBroadcastFailureMessage(
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

        private nonisolated static func startFailureAlert(for error: Error) -> RealtimeStartFailureAlert {
            RealtimeStartFailureAlert(
                title: String(localized: "Realtime Failed"),
                message: startFailureAlertMessage(for: error)
            )
        }

        @available(iOS 17.4, macOS 14.4, *)
        nonisolated static func appleTranslateLanguagePreflightFailure(
            status: LanguageAvailability.Status,
            languagePair: String
        ) -> LocalProviderError? {
            switch status {
            case .installed, .supported:
                return nil
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
            guard !translation.isEmpty else { return [] }

            guard !source.isEmpty else { return [] }
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

        private nonisolated static func joinedHistoryText(_ translatedText: String, _ pendingTranslatedText: String) -> String {
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

    private extension RealtimeSessionStore {
        func logRealtime(_ message: String) {
            realtimeLogger.debug("[Realtime] \(message, privacy: .public)")
        }

        func assignIfChanged<Value: Equatable>(_ value: inout Value, _ newValue: Value) {
            if value != newValue {
                value = newValue
            }
        }

        var resolvedCaptionDisplayMode: RealtimeCaptionDisplayMode {
            #if os(iOS)
                if inputSource == .iphoneAudio {
                    return captionDisplayMode
                }
            #endif
            let provider = preferences.realtimeTranslationProvider
            if !provider.performsTranslation {
                return .sourceOnly
            }
            return captionDisplayMode
        }

        func refreshCaptionLines(event: String) {
            let startedAt = Date()
            let allLines = resolvedCaptionLines()
            let visibleLines = RealtimeCaptionDisplay.displayWindow(
                RealtimeCaptionDisplay.linesVisibleAfterClear(allLines, anchor: captionClearAnchor),
                limit: Self.captionLineDisplayLimit
            )
            assignIfChanged(&captionLines, visibleLines)
            let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
            logRealtime(
                """
                captionLines refreshed event=\(event) sourceSegments=\(presentationSourceSegments.count) \
                pairs=\(sentencePairs.count) allLines=\(allLines.count) visibleLines=\(visibleLines.count) \
                elapsedMs=\(String(format: "%.2f", elapsedMs))
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

        func logPresentation(_ event: String) {
            let lineSummary = Self.captionLineSummary(captionLines)
            logRealtime(
                """
                \(event) presentation sourceLen=\(sourceText.count) stableLen=\(translationSourceText.count) \
                pendingLen=\(pendingSourceText.count) translatedLen=\(translatedText.count) \
                pendingTranslationLen=\(pendingTranslatedText.count) pairs=\(sentencePairs.count) \
                sourceSegments=\(presentationSourceSegments.count) visibleLines=\(captionLines.count) \
                lines=\(lineSummary) showUntranslated=true \
                mode=\(captionDisplayMode.rawValue) queuedFinal=\(queuedFinalTranslationRequests.count) \
                finalTask=\(finalTranslationTask != nil) partialTask=\(partialTranslationTask != nil) \
                latestPartial=\(latestPartialTranslationRequest != nil)
                """
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
                    iphoneBroadcast state session=\(state.sessionID) phase=\(state.phase.rawValue) \
                    sourceLen=\(state.sourceText.count) stableLen=\(state.translationSourceText.count) \
                    pendingLen=\(state.pendingSourceText.count) translatedLen=\(state.translatedText.count) \
                    pendingTranslationLen=\(state.pendingTranslatedText.count) pairs=\(state.sentencePairs.count) \
                    audioSamples=\(state.audioSampleCount) error=\(state.errorMessage ?? "")
                    """
                )
            }
        #endif

        static func captionLineSummary(_ lines: [RealtimeCaptionLine]) -> String {
            guard !lines.isEmpty else { return "empty" }
            return lines.map { line in
                let kind: String
                switch line.kind {
                case .source:
                    kind = "source"
                case .translation:
                    kind = "translation"
                }
                let pending = line.isPending ? "*" : ""
                return "\(kind)\(pending):\(line.text.count)"
            }.joined(separator: ",")
        }

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

        nonisolated static func preview(_ text: String, limit: Int = 80) -> String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard normalized.count > limit else { return normalized }
            return "\(normalized.prefix(limit))..."
        }

        private func shouldAcceptRealtimeCallback(sessionID: UUID) -> Bool {
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
            logPresentation("updateTranscriptPresentation")
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
            queuedFinalTranslationRequests.append(contentsOf: requests)

            let queuedCount = queuedFinalTranslationRequests.count
            logRealtime(
                """
                enqueueFinalTranslationRequests provider=\(provider.rawValue) missing=\(requests.count) \
                queued=\(queuedCount) requests=\(requests.map { Self.preview($0.translationText) }.joined(separator: " | "))
                """
            )
            guard finalTranslationTask == nil else { return }
            logRealtime("finalTranslationTask started queued=\(queuedFinalTranslationRequests.count)")
            finalTranslationTask = Task { @MainActor [weak self] in
                await self?.processFinalTranslationRequests()
            }
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
                    logRealtime("schedulePartialTranslation noRequest reason=emptyPending")
                    cancelPartialTranslationWork()
                    syncTranslationStatePresentation()
                } else {
                    logRealtime(
                        """
                        schedulePartialTranslation skippedDuplicate provider=\(provider.rawValue) \
                        pendingLen=\(translationState.pendingSourceText.count)
                        """
                    )
                }
                return
            }

            latestPartialTranslationRequest = request
            logRealtime(
                """
                schedulePartialTranslation queued provider=\(provider.rawValue) \
                requestLen=\(request.translationText.count) text=\(Self.preview(request.translationText))
                """
            )
            guard partialTranslationTask == nil else { return }
            logRealtime("partialTranslationTask started")
            partialTranslationTask = Task { @MainActor [weak self] in
                await self?.processPartialTranslationRequests()
            }
        }

        func applyFinalTranslationResult(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) {
            guard requestMatchesCurrentConfiguration(request) else {
                logRealtime(
                    """
                    applyFinalTranslationResult discarded reason=configChanged \
                    request=\(Self.preview(request.translationText))
                    """
                )
                translationState.finishFinalTranslationRequest(request)
                syncTranslationStatePresentation()
                return
            }

            switch result.response {
            case let .success(text):
                logRealtime(
                    """
                    applyFinalTranslationResult success provider=\(request.provider.rawValue) responseLen=\(text.count) \
                    resultPairs=\(result.sentencePairs.count) request=\(Self.preview(request.translationText))
                    """
                )
                let applied = translationState.applyFinalTranslationSuccess(result, request: request)
                logRealtime(
                    """
                    applyFinalTranslationResult applied=\(applied) stableLen=\(translationState.translationSourceText.count) \
                    translatedLen=\(translationState.translatedText.count) pairs=\(translationState.sentencePairs.count)
                    """
                )
                syncTranslationStatePresentation()
            case let .failure(error):
                let message = Self.translationErrorMessage(
                    error,
                    source: request.source,
                    target: request.targetLanguage,
                    provider: request.provider
                )
                logRealtime(
                    "applyFinalTranslationResult failure error=\(message)"
                )
                translationState.finishFinalTranslationRequest(request)
                syncTranslationStatePresentation()
                handleErrorMessage(message)
            }
        }

        func applyPartialTranslationResult(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) {
            guard requestMatchesCurrentConfiguration(request) else {
                logRealtime(
                    """
                    applyPartialTranslationResult discarded reason=configChanged \
                    request=\(Self.preview(request.translationText))
                    """
                )
                return
            }

            switch result.response {
            case let .success(text):
                logRealtime(
                    """
                    applyPartialTranslationResult success provider=\(request.provider.rawValue) responseLen=\(text.count) \
                    resultPairs=\(result.sentencePairs.count) request=\(Self.preview(request.translationText))
                    """
                )
                if translationState.applyPartialTranslationSuccess(result, request: request) {
                    logRealtime(
                        """
                        applyPartialTranslationResult applied pendingLen=\(translationState.pendingSourceText.count) \
                        pendingTranslationLen=\(translationState.pendingTranslatedText.count)
                        """
                    )
                    syncTranslationStatePresentation()
                    updateStatusAfterTranslationActivity()
                } else {
                    logRealtime(
                        """
                        applyPartialTranslationResult discarded reason=stalePending \
                        currentPendingLen=\(translationState.pendingSourceText.count)
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
                logRealtime(
                    "applyPartialTranslationResult failure error=\(message)"
                )
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
            let hasTranslationWork = finalTranslationTask != nil ||
                partialTranslationTask != nil ||
                !queuedFinalTranslationRequests.isEmpty ||
                latestPartialTranslationRequest != nil
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
            let hadWork = finalTranslationTask != nil ||
                partialTranslationTask != nil ||
                !queuedFinalTranslationRequests.isEmpty ||
                latestPartialTranslationRequest != nil
            if hadWork {
                logRealtime(
                    """
                    cancelTranslationWork finalTask=\(finalTranslationTask != nil) \
                    partialTask=\(partialTranslationTask != nil) \
                    queuedFinal=\(queuedFinalTranslationRequests.count) \
                    latestPartial=\(latestPartialTranslationRequest != nil)
                    """
                )
            }
            finalTranslationTask?.cancel()
            finalTranslationTask = nil
            queuedFinalTranslationRequests.removeAll()
            translationState.cancelQueuedFinalTranslationRequests()
            cancelPartialTranslationWork()
        }

        func cancelPartialTranslationWork() {
            if partialTranslationTask != nil || latestPartialTranslationRequest != nil {
                logRealtime(
                    """
                    cancelPartialTranslationWork task=\(partialTranslationTask != nil) \
                    latestPartial=\(latestPartialTranslationRequest != nil)
                    """
                )
            }
            partialTranslationTask?.cancel()
            partialTranslationTask = nil
            latestPartialTranslationRequest = nil
            nextPartialTranslationAllowedAt = nil
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

    #if os(macOS) && arch(arm64) && canImport(FluidAudio)
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

                let completedAudioSegment = audioHistoryRecorder.append(sampleBuffer)
                realtimePipelineAudioFanout.append(sampleBuffer)
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

            let completedAudioSegment = audioHistoryRecorder.append(sampleBuffer)
            #if os(macOS)
                realtimePipelineAudioFanout.append(sampleBuffer)
            #else
                activeRecognizer.append(sampleBuffer)
            #endif
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

            let completedAudioSegment = audioHistoryRecorder.append(pcmBuffer)
            #if os(macOS)
                realtimePipelineAudioFanout.append(pcmBuffer)
            #else
                activeRecognizer.append(pcmBuffer)
            #endif
            if completedAudioSegment {
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
#endif
