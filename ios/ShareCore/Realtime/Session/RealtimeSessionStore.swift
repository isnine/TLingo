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


    public struct RealtimeStartFailureAlert: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let message: String
        /// The start failed only because an Apple Translate language pack is missing; starting
        /// again shows the system download prompt.
        public let offersAppleTranslationDownload: Bool

        public init(
            id: UUID = UUID(),
            title: String,
            message: String,
            offersAppleTranslationDownload: Bool = false
        ) {
            self.id = id
            self.title = title
            self.message = message
            self.offersAppleTranslationDownload = offersAppleTranslationDownload
        }
    }

    #if os(macOS)
        public struct RealtimeModelDownload: Identifiable, Equatable {
            public let id: String
            public let title: String
            public var progress: Double

            public init(id: String, title: String, progress: Double) {
                self.id = id
                self.title = title
                self.progress = progress
            }
        }
    #endif

    @MainActor
    public final class RealtimeSessionStore: ObservableObject {
        public static let shared = RealtimeSessionStore()
        #if os(macOS)
            private static let captionLineDisplayLimit = 160
        #endif
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
        /// Set after a stopped session (with saved audio) is written to History; views show a tappable notice.
        @Published public private(set) var savedHistoryNotice: RealtimeSavedHistoryNotice?
        /// Set while a start waits for a local recognition model to finish loading.
        @Published public private(set) var recognitionModelLoad: RealtimeModelLoadProgress?
        /// Set while a start waits for the system Apple Translate download prompt. Language packs can
        /// only be downloaded through `prepareTranslation()` on a session from `.translationTask`,
        /// so realtime views host that modifier and hand the session back. Kept after a request so a
        /// retry for the same pair can `invalidate()` it: `.translationTask` ignores an equal new value.
        @Published public private(set) var appleTranslationDownloadConfiguration: TranslationSession.Configuration?
        private var appleTranslationDownloadRequestID: UUID?
        private var isAppleTranslationDownloadPromptPresented = false
        /// The system download prompt only appears when the user asks for it from the start failure alert.
        private var allowsAppleTranslationDownloadPromptOnNextStart = false
        private var appleTranslationDownloadContinuation: CheckedContinuation<Void, Never>?
        /// Not `@Published`: level updates arrive ~20 times per second and would redraw every
        /// observer of the store. Views read `inputLevel` instead.
        public private(set) var audioLevel: Float? {
            didSet { inputLevel.update(decibels: audioLevel) }
        }

        public private(set) var audioSampleCount = 0
        public let inputLevel = RealtimeInputLevel()
        #if os(macOS)
            @Published public private(set) var laneConfigurations: [RealtimeLaneConfiguration] = []
            @Published public private(set) var laneSnapshots: [RealtimeLaneSnapshot] = []
            @Published public private(set) var primaryLaneID = UUID()
            @Published public private(set) var isRealtimeMemoryConstrained = false
            @Published public private(set) var importedAudioURL: URL?
            @Published public private(set) var modelDownloads: [RealtimeModelDownload] = []
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

        #if os(macOS)
            public func updateModelDownload(
                id: String,
                title: String,
                progress: Double
            ) {
                let download = RealtimeModelDownload(
                    id: id,
                    title: title,
                    progress: min(max(progress, 0), 1)
                )
                if let index = modelDownloads.firstIndex(where: { $0.id == id }) {
                    modelDownloads[index] = download
                } else {
                    modelDownloads.append(download)
                }
            }

            public func removeModelDownload(id: String) {
                modelDownloads.removeAll { $0.id == id }
            }
        #endif

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
        /// Latest recognizer audio position; a history session started mid-run (transcript
        /// cleared) begins its recording here.
        private var recognitionAudioPosition: TimeInterval = 0
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
        private var lastCaptionDiagnosticsSignature: String?
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
            /// Set while Picture in Picture shows the captions, so leaving the app keeps microphone capture running.
            public var continuesInBackground = false
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
                guard laneConfigurations.count > 1,
                      laneConfigurations.contains(where: { $0.id == id })
                else {
                    return
                }
                // Remove before suspending so a concurrent removal sees the updated count.
                laneConfigurations.removeAll { $0.id == id }
                laneSnapshots.removeAll { $0.id == id }
                if isRunning {
                    await realtimePipelineCoordinator.removeLane(id: id)
                }
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
                model=\(preferences.realtimeRecognitionModelID) source=\(preferences.realtimeSourceLanguage.rawValue) \
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
            publishSavedHistoryNoticeIfNeeded()
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

        public func dismissSavedHistoryNotice() {
            savedHistoryNotice = nil
        }

        /// Starts loading the selected local recognition model so a later start does not wait for it.
        public func prewarmRecognitionModel() async {
            #if os(iOS) && arch(arm64) && canImport(FluidAudio)
                guard !isRunning, !isStarting, inputSource == .microphone else { return }
                let model = RecognitionModelStore.selectableDescriptor(
                    forModelID: preferences.realtimeRecognitionModelID
                )
                guard model.runtime == .fluidAudio,
                      await RecognitionModelStore.shared.isModelCached(model)
                else {
                    return
                }
                await RealtimeFluidAudioEngineCache.shared.prewarm(model)
            #endif
        }

        private func publishSavedHistoryNoticeIfNeeded() {
            let recordingCount = lastRealtimeHistoryAutosaveRecordings?.count ?? 0
            logRealtime("saved history notice recordings=\(recordingCount)")
            guard recordingCount > 0 else { return }
            savedHistoryNotice = RealtimeSavedHistoryNotice(requestID: historySessionBuilder.requestID)
        }

        public func dismissStartFailureAlert() {
            startFailureAlert = nil
        }

        /// Lets the next start show the system Apple Translate download prompt for a missing language pack.
        public func allowAppleTranslationDownloadOnNextStart() {
            allowsAppleTranslationDownloadPromptOnNextStart = true
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
                            guard self?.continuesInBackground != true else { return }
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
                    start requested source=\(preferences.realtimeSourceLanguage.rawValue) \
                    target=\(preferences.realtimeTargetLanguage.rawValue)
                    """,
                    stage: "broadcast"
                )
                if let failure = await RealtimeIPhoneAudioPreflight.evaluate(
                    sourceLanguage: preferences.realtimeSourceLanguage,
                    targetLanguage: preferences.realtimeTargetLanguage
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

                let sessionID = UUID().uuidString
                broadcastStateStore?.reset(sessionID: sessionID, phase: .waiting)
                isRunning = true
                statusText = String(localized: "Waiting for iPhone Audio broadcast")
                lastBroadcastStateLogSignature = nil
                logRealtime("waiting session=\(sessionID)", stage: "broadcast")
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
                logRealtime("finished status=\(status)", stage: "broadcast")
            }
        #endif

        private func startRecognition(sessionID: UUID) async throws -> Int {
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
                    statusText = String(localized: "Preparing speech recognition...")
                    switch model.runtime {
                    case .appleSpeech:
                        try await transcriber.start(model: model, locale: speechLocale(), sessionID: sessionID)
                        activeRecognizer.set(transcriber)
                        return transcriber.sampleRate
                    case .fluidAudio:
                        #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
                            if let progress = await RealtimeFluidAudioEngineCache.shared.loadProgress(for: model) {
                                statusText = String(localized: "Loading recognition model...")
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
                }
                if let error = Self.appleTranslateLanguagePreflightFailure(
                    status: status,
                    languagePair: languagePair
                ) {
                    throw error
                }
            }
        }

        private func requestAppleTranslationLanguageDownload(
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

        private static func hasSameStrategy(
            _ lhs: TranslationSession.Configuration,
            _ rhs: TranslationSession.Configuration
        ) -> Bool {
            guard #available(iOS 26.4, macOS 26.4, *) else { return true }
            return lhs.preferredStrategy == rhs.preferredStrategy
        }

        private func finishAppleTranslationLanguageDownload(requestID: UUID?) {
            guard let requestID, requestID == appleTranslationDownloadRequestID else { return }
            appleTranslationDownloadRequestID = nil
            appleTranslationDownloadContinuation?.resume()
            appleTranslationDownloadContinuation = nil
        }

        private func handleRecognized(_ result: RealtimeRecognitionResult) {
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
        private static func recognitionTimings(
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

        private func processFinalTranslationRequests() async {
            while !Task.isCancelled {
                guard !queuedFinalTranslationRequests.isEmpty else {
                    finalTranslationTask = nil
                    updateStatusAfterTranslationActivity()
                    if isPaused {
                        saveRealtimeHistoryIfPossible()
                    }
                    return
                }
                let request = queuedFinalTranslationRequests.removeFirst()

                do {
                    guard !Task.isCancelled else { return }
                    let result = try await RealtimeTranslationService.translate(request)
                    guard !Task.isCancelled else { return }
                    applyFinalTranslationResult(result, request: request)
                    if !queuedFinalTranslationRequests.isEmpty {
                        try await Task.sleep(for: .milliseconds(Int((request.cadenceInterval * 1000).rounded(.up))))
                    }
                } catch is CancellationError {
                    // The canceller already cleared the handle and may have scheduled a replacement.
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
                    RealtimeLog.warn("tx", "final error src=\(RealtimeLog.text(request.translationText)) error=\(message)")
                    handleErrorMessage(message)
                }
            }
        }

        private func processPartialTranslationRequests() async {
            while !Task.isCancelled {
                guard var request = latestPartialTranslationRequest else {
                    partialTranslationTask = nil
                    nextPartialTranslationAllowedAt = nil
                    updateStatusAfterTranslationActivity()
                    return
                }
                latestPartialTranslationRequest = nil

                do {
                    let allowedAt = nextPartialTranslationAllowedAt ?? Date().addingTimeInterval(request.cadenceInterval)
                    nextPartialTranslationAllowedAt = allowedAt
                    let delay = allowedAt.timeIntervalSinceNow
                    if delay > 0 {
                        try await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
                    }

                    if let newerRequest = latestPartialTranslationRequest {
                        request = newerRequest
                        latestPartialTranslationRequest = nil
                    }

                    guard !Task.isCancelled else { return }
                    nextPartialTranslationAllowedAt = Date().addingTimeInterval(request.cadenceInterval)
                    let result = try await RealtimeTranslationService.translate(request)
                    guard !Task.isCancelled else { return }
                    applyPartialTranslationResult(result, request: request)
                } catch is CancellationError {
                    // The canceller already cleared the handle and may have scheduled a replacement.
                    return
                } catch {
                    let message = Self.translationErrorMessage(
                        error,
                        source: request.source,
                        target: request.targetLanguage,
                        provider: request.provider
                    )
                    RealtimeLog.warn("tx", "partial error src=\(RealtimeLog.text(request.translationText)) error=\(message)")
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
                message: startFailureAlertMessage(for: error),
                offersAppleTranslationDownload: {
                    if case .languagePackNotInstalled? = error as? LocalProviderError { return true }
                    return false
                }()
            )
        }

        @available(iOS 17.4, macOS 14.4, *)
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
        func logRealtime(_ message: String, stage: String = "session") {
            RealtimeLog.log(stage, message)
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
            let allLines = resolvedCaptionLines()
            let visibleLines = RealtimeCaptionDisplay.linesVisibleAfterClear(allLines, anchor: captionClearAnchor)
            #if os(macOS)
                let displayLines = RealtimeCaptionDisplay.displayWindow(visibleLines, limit: Self.captionLineDisplayLimit)
            #else
                let displayLines = visibleLines
            #endif
            if captionLines != displayLines {
                logCaptionDiagnostics(event: event, allLines: allLines, displayLines: displayLines)
            }
            assignIfChanged(&captionLines, displayLines)
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
            let hasTranslationWork = finalTranslationTask != nil || !queuedFinalTranslationRequests.isEmpty
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

            RealtimeLog.log(
                "tx",
                """
                enqueue final +\(requests.count) queued=\(queuedFinalTranslationRequests.count) \
                segs=\(translationState.sourceSegments.count) src=\(RealtimeLog.segments(requests.map(\.translationText)))
                """
            )
            guard finalTranslationTask == nil else { return }
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
                    cancelPartialTranslationWork()
                    syncTranslationStatePresentation()
                }
                return
            }

            latestPartialTranslationRequest = request
            guard partialTranslationTask == nil else { return }
            partialTranslationTask = Task { @MainActor [weak self] in
                await self?.processPartialTranslationRequests()
            }
        }

        func applyFinalTranslationResult(
            _ result: ModelExecutionResult,
            request: RealtimeTextTranslationRequest
        ) {
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
                RealtimeLog.log(
                    "tx",
                    """
                    cancel finalTask=\(finalTranslationTask != nil) \
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

    #if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
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

public struct RealtimeSavedHistoryNotice: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let requestID: UUID
}

public struct RealtimeModelLoadProgress: Equatable, Sendable {
    public let startedAt: Date
    /// Last measured load time for this model; nil before the first load finishes.
    public let estimatedDuration: TimeInterval?

    /// Estimated completion, capped below 1 because the real load has no progress callback.
    public func fraction(at date: Date) -> Double? {
        guard let estimatedDuration, estimatedDuration > 0 else { return nil }
        return min(date.timeIntervalSince(startedAt) / estimatedDuration, 0.95)
    }
}
