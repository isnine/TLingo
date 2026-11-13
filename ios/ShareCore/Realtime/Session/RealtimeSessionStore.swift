#if os(iOS)
    import UIKit
#endif
import AVFoundation
import Combine
import CoreMedia
import Foundation
import os
import Translation

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
        static let captionLineDisplayLimit = 160
    #endif
    static let realtimeHistoryAutosaveInterval: TimeInterval = 5

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
            if !isApplyingCaptionModePreference {
                preferences.setRealtimeCaptionDisplayMode(captionDisplayMode)
            }
            #if os(macOS)
                realtimePipelineCoordinator.updateCaptionDisplayMode(captionDisplayMode)
                refreshInactiveLaneCaptionPresentation()
            #endif
            refreshCaptionLines(event: "captionDisplayModeChanged")
        }
    }

    @Published public internal(set) var isRunning = false
    @Published public internal(set) var isStarting = false
    @Published public internal(set) var isStopping = false
    /// A producer failure reported while `start()` is still bringing capture up.
    var pendingStartFailure: Error?
    @Published public internal(set) var isPaused = false
    @Published public internal(set) var sourceText = ""
    @Published public internal(set) var translatedText = ""
    @Published public internal(set) var translationSourceText = ""
    @Published public internal(set) var sentencePairs: [SentencePair] = []
    @Published public internal(set) var pendingSourceText = ""
    @Published public internal(set) var pendingTranslatedText = ""
    @Published public internal(set) var captionLines: [RealtimeCaptionLine] = []
    /// Bumped on every `captionLines` change so `[RT][ui]` and `[RT][view]` logs share one id.
    public internal(set) var captionRevision = 0
    @Published public internal(set) var statusText = String(localized: "Ready")
    @Published public internal(set) var errorMessage: String?
    @Published public internal(set) var startFailureAlert: RealtimeStartFailureAlert?
    /// Set after a stopped session (with saved audio) is written to History; views show a tappable notice.
    @Published public internal(set) var savedHistoryNotice: RealtimeSavedHistoryNotice?
    /// Set while a start waits for a local recognition model to finish loading.
    @Published public internal(set) var recognitionModelLoad: RealtimeModelLoadProgress?
    /// Title of the recognition model a start is loading; views abbreviate it to fit one line.
    @Published public internal(set) var loadingRecognitionModelTitle: String?
    /// Set while a start waits for the system Apple Translate download prompt. Language packs can
    /// only be downloaded through `prepareTranslation()` on a session from `.translationTask`,
    /// so realtime views host that modifier and hand the session back. Kept after a request so a
    /// retry for the same pair can `invalidate()` it: `.translationTask` ignores an equal new value.
    @Published public internal(set) var appleTranslationDownloadConfiguration: TranslationSession.Configuration?
    var appleTranslationDownloadRequestID: UUID?
    var isAppleTranslationDownloadPromptPresented = false
    /// The system download prompt only appears when the user asks for it from the start failure alert.
    var allowsAppleTranslationDownloadPromptOnNextStart = false
    var appleTranslationDownloadContinuation: CheckedContinuation<Void, Never>?
    /// Not `@Published`: level updates arrive ~20 times per second and would redraw every
    /// observer of the store. Views read `inputLevel` instead.
    public internal(set) var audioLevel: Float? {
        didSet { inputLevel.update(decibels: audioLevel) }
    }

    public internal(set) var audioSampleCount = 0
    public let inputLevel = RealtimeInputLevel()
    #if os(macOS)
        @Published public internal(set) var laneConfigurations: [RealtimeLaneConfiguration] = []
        @Published public internal(set) var laneSnapshots: [RealtimeLaneSnapshot] = []
        @Published public internal(set) var primaryLaneID = UUID()
        @Published public internal(set) var isRealtimeMemoryConstrained = false
        @Published public internal(set) var importedAudioURL: URL?
        @Published public internal(set) var modelDownloads: [RealtimeModelDownload] = []
    #else
        /// True once the iPhone Audio broadcast extension is recognizing app audio.
        @Published public internal(set) var isIPhoneAudioCaptureReady = false
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

    nonisolated let transcriber = RealtimeLiveSpeechTranscriber()
    nonisolated let activeRecognizer = RealtimeRecognizerSlot()
    nonisolated let callbackDrain = RealtimeCallbackDrain()
    #if os(macOS)
        nonisolated let systemAudioCapture = RealtimeSystemAudioCapture()
        nonisolated let secondarySystemAudioCapture = RealtimeSystemAudioCapture()
        nonisolated let realtimePipelineAudioFanout = RealtimePipelineAudioFanout()
        let realtimePipelineCoordinator: RealtimePipelineCoordinator
    #endif
    nonisolated let microphoneAudioCapture = RealtimeMicrophoneAudioCapture()
    #if os(macOS)
        nonisolated let secondaryMicrophoneAudioCapture = RealtimeMicrophoneAudioCapture()
    #endif
    nonisolated let audioHistoryRecorder = RealtimeAudioHistoryRecorder()
    nonisolated let secondaryAudioHistoryRecorder = RealtimeAudioHistoryRecorder()

    let preferences: AppPreferences
    var captionModeObservation: AnyCancellable?
    var isApplyingCaptionModePreference = false
    var transcriptAccumulator = RealtimeTranscriptAccumulator()
    var translationState = RealtimeIncrementalTranslationState()
    var presentationSourceSegments: [String] = []
    var captionClearAnchor = RealtimeCaptionDisplayClearAnchor.empty
    var historyCheckpoint = RealtimeHistoryCheckpoint()
    var historySessionBuilder = RealtimeHistorySessionBuilder()
    /// Latest recognizer audio position; a history session started mid-run (transcript
    /// cleared) begins its recording here.
    var recognitionAudioPosition: TimeInterval = 0
    var lastRealtimeHistoryAutosaveAt: Date?
    var lastRealtimeHistoryAutosaveSegments: [RealtimeHistorySegment]?
    var lastRealtimeHistoryAutosaveRecordings: [RealtimeHistoryAudioRecording]?
    var lastRealtimeHistoryAutosaveTracks: [RealtimeHistoryTrack]?
    #if os(macOS)
        var secondaryAudioSource: RealtimeAudioInputSource?
        var importedAudioTask: Task<Void, Never>?
        var isImportedAudioSession = false
        var preMOSSRecognitionModelIDs: [UUID: String] = [:]
    #endif
    let translationScheduler = RealtimeTranslationScheduler()
    var realtimeHistoryAutosaveTask: Task<Void, Never>?
    var realtimeHistoryTitleTasks: [UUID: Task<Void, Never>] = [:]
    var realtimeHistoryTitleRequestIDs: Set<UUID> = []
    var lastBroadcastStateLogSignature: String?
    var lastAppliedBroadcastSourceSegments: [String] = []
    var lastCaptionDiagnosticsSignature: String?
    /// Origin of the next caption refresh (`asr#12`, `txp#3`, `txf#4`), carried into `[RT][ui]`.
    var captionUpdateCause = "-"
    var captionTraceSequence = 0
    var lastCaptionRevisionTime: ContinuousClock.Instant?
    var activeSessionID = UUID()
    var drainingSessionID: UUID?
    #if os(iOS)
        public static let broadcastUploadExtensionBundleIdentifier = "com.zanderwang.AITranslator.BroadcastUpload"
        nonisolated static let broadcastPickerWaitTimeout: TimeInterval = 15

        let broadcastStateStore: RealtimeBroadcastStateStore?
        var broadcastStatePollingTask: Task<Void, Never>?
        var sessionLifecycleObservers: [NSObjectProtocol] = []
        /// Set when an audio interruption paused the microphone, so its end may resume it.
        var isPausedForAudioInterruption = false
        var latestBroadcastRealtimeHistorySession: RealtimeHistorySession?
        /// True for an iPhone Audio session whose relayed audio the host recognizes with a local
        /// model; the host then owns the transcript and history instead of the extension.
        var usesHostRecognitionRelay = false
        var hostRecognitionRelayTask: Task<Void, Never>?
        var hostRecognitionRelayReader: RealtimeAudioRelayReader?
        var isDrainingHostRecognitionRelay = false
        nonisolated static let hostRecognitionRelayPollInterval: Duration = .milliseconds(50)
        /// Audio older than this after a stall is dropped instead of overflowing the recognizer backlog.
        nonisolated static let hostRecognitionRelayMaximumChunkDuration: TimeInterval = 10
    #endif

    public init(preferences: AppPreferences = .shared) {
        defer { configureTranslationScheduler() }
        #if os(macOS)
            realtimePipelineCoordinator = RealtimePipelineCoordinator(
                audioFanout: realtimePipelineAudioFanout
            )
        #endif
        self.preferences = preferences
        showCaptions = preferences.realtimeShowCaptions
        captionDisplayMode = preferences.realtimeCaptionDisplayMode
        #if os(iOS)
            broadcastStateStore = RealtimeBroadcastStateStore()
        #endif
        transcriber.delegate = self
        captionModeObservation = preferences.$realtimeCaptionDisplayMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self, captionDisplayMode != mode else { return }
                isApplyingCaptionModePreference = true
                captionDisplayMode = mode
                isApplyingCaptionModePreference = false
            }
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
            registerSessionLifecycle()
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
            for observer in sessionLifecycleObservers {
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
                isMemoryConstrained: isRealtimeMemoryConstrained,
                sourceLanguage: preferences.realtimeSourceLanguage
            )
        }

        nonisolated static func startConfigurationBlocker(
            configurations: [RealtimeLaneConfiguration],
            hasImportedAudio: Bool,
            isMemoryConstrained: Bool,
            sourceLanguage: SourceLanguageOption = .auto,
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
                guard model.supports(sourceLanguage: sourceLanguage) else {
                    return .unsupportedSourceLanguage(model.title, sourceLanguage.primaryLabel)
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
            guard model.runtime != .mossOffline || hasImportedAudio,
                  model.supports(sourceLanguage: preferences.realtimeSourceLanguage) else { return }
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

        var isRealtimeSessionBusy: Bool {
            isRunning || isStarting || isStopping
        }

        func persistLaneConfiguration() {
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

        func restorePreMOSSRecognitionModels() {
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

        func applyLaneSnapshots(_ snapshots: [RealtimeLaneSnapshot]) {
            var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
            laneSnapshots = laneConfigurations.compactMap { configuration in
                snapshotsByID.removeValue(forKey: configuration.id) ??
                    laneSnapshots.first(where: { $0.id == configuration.id }) ??
                    RealtimeLaneSnapshot(configuration: configuration)
            }
            projectPrimaryLane()
            autosaveRealtimeHistoryIfNeeded()
        }

        func projectPrimaryLane() {
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
            refreshInactiveLaneCaptionPresentation()
            projectPrimaryLane()
        }

        func refreshInactiveLaneCaptionPresentation() {
            let activeLaneIDs = Set(realtimePipelineCoordinator.snapshots.map(\.id))
            laneSnapshots = laneSnapshots.map { snapshot in
                guard !activeLaneIDs.contains(snapshot.id) else { return snapshot }
                var updated = snapshot
                updated.captionLines = RealtimeCaptionDisplay.displayWindow(
                    RealtimeCaptionDisplay.resolvedLines(
                        pairs: snapshot.sentencePairs,
                        translatedSource: snapshot.sentencePairs.map(\.original).joined(separator: "\n\n"),
                        translatedText: snapshot.translatedText,
                        pendingSource: snapshot.pendingSourceText,
                        pendingTranslation: snapshot.pendingTranslatedText,
                        sourceText: snapshot.sourceText,
                        mode: snapshot.configuration.translationProvider.performsTranslation
                            ? captionDisplayMode : .sourceOnly
                    ),
                    limit: Self.captionLineDisplayLimit
                )
                return updated
            }
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
        pendingStartFailure = nil
        defer {
            isStarting = false
            pendingStartFailure = nil
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
                    if let pendingStartFailure {
                        throw pendingStartFailure
                    }
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
            if let pendingStartFailure {
                throw pendingStartFailure
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
                await drainHostRecognitionRelay()
                saveRealtimeHistoryIfPossible()
                guard let broadcastStateStore else {
                    finishIPhoneAudioBroadcastSession(status: String(localized: "Stopped"))
                    return
                }
                // Capture the phase before requestStop() overwrites it with .stopping.
                let priorState = broadcastStateStore.load()
                let priorPhase = priorState?.phase
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
                    await waitForIPhoneAudioBroadcastStop(sessionID: priorState?.sessionID)
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
        await translationScheduler.settle()
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

    func publishSavedHistoryNoticeIfNeeded() {
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
        #if os(iOS)
            isPausedForAudioInterruption = false
            // An interruption stops the engine; resuming must restart it before recognition continues.
            if isPaused, inputSource == .microphone {
                do {
                    try microphoneAudioCapture.restartIfStopped()
                } catch {
                    logRealtime("microphone resume failed error=\(Self.describe(error))")
                    errorMessage = Self.realtimeErrorDescription(for: error)
                    return
                }
            }
        #endif
        let isTranslating = translationScheduler.isTranslating
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

    #if os(iOS)
        /// True while the upload extension is broadcasting for this session. A stop the extension
        /// initiates always shows a ReplayKit alert, so the UI ends a live broadcast through the
        /// system picker instead.
        public var isIPhoneAudioBroadcastLive: Bool {
            guard inputSource == .iphoneAudio, isRunning, !isStopping,
                  let phase = broadcastStateStore?.load()?.phase
            else { return false }
            switch phase {
            case .broadcasting, .recognizing, .translating, .paused:
                return true
            case .idle, .waiting, .stopping, .stopped, .failed:
                return false
            }
        }
    #endif

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
        #if os(iOS)
            inputSource = SnapshotLaunchArguments.isSnapshotMode()
                && SnapshotLaunchArguments.value(after: "-SNAPSHOT_SCENE") == "video"
                ? .iphoneAudio : .microphone
        #else
            inputSource = .microphone
        #endif
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
}

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
