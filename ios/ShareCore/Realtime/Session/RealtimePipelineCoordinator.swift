#if os(macOS)
    import AVFoundation
    import CoreMedia
    import Foundation
    import os

    let realtimePipelineLogger = Logger(
        subsystem: "com.zanderwang.AITranslator",
        category: "RealtimePipeline"
    )

    @MainActor
    final class RealtimePipelineCoordinator {
        nonisolated static let maximumLaneCount = 3

        nonisolated let audioFanout: RealtimePipelineAudioFanout

        var onSnapshotsChanged: (([RealtimeLaneSnapshot]) -> Void)?
        var onFailure: ((UUID?, Error) -> Void)?
        var onMemoryPressureChanged: ((Bool) -> Void)?
        var onLaneTerminated: ((UUID, String) -> Void)?

        var configurations: [RealtimeLaneConfiguration] = []
        var primaryLaneID: UUID?
        var recognitionNodes: [String: RealtimeRecognitionNode] = [:]
        var recognitionSubscribers: [String: Set<UUID>] = [:]
        var laneRuntimes: [UUID: RealtimeLaneRuntime] = [:]
        var completedTracks: [RealtimeHistoryTrack] = []
        var activeSessionID = UUID()
        var sourceLanguage: SourceLanguageOption = .auto
        var targetLanguage: TargetLanguageOption = .appLanguage
        var captionDisplayMode: RealtimeCaptionDisplayMode = .bilingual
        var startedAt: Date?
        var pausedAt: Date?
        var pausedDuration: TimeInterval = 0
        var isRunning = false
        var isStopping = false
        var memoryPressureSource: DispatchSourceMemoryPressure?
        var isUnderMemoryPressure = false
        var didEncounterCriticalMemoryPressure = false
        var recognitionLagBreachCounts: [String: Int] = [:]
        var didEncounterSustainedRecognitionLag = false
        var audioSource: RealtimeHistoryAudioSource?
        var mossTask: Task<Void, Never>?
        var deferredMOSSURL: URL?
        nonisolated let callbackDrain = RealtimeCallbackDrain()

        init(audioFanout: RealtimePipelineAudioFanout = RealtimePipelineAudioFanout()) {
            self.audioFanout = audioFanout
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                guard let source else { return }
                Task { @MainActor in
                    await self?.handleMemoryPressure(source.data)
                }
            }
            source.resume()
            memoryPressureSource = source
        }

        var snapshots: [RealtimeLaneSnapshot] {
            configurations.compactMap { laneRuntimes[$0.id]?.snapshot }
        }

        var tracks: [RealtimeHistoryTrack] {
            completedTracks + configurations.compactMap { laneRuntimes[$0.id]?.trackSnapshot() }
        }

        func start(
            configurations: [RealtimeLaneConfiguration],
            primaryLaneID: UUID,
            sourceLanguage: SourceLanguageOption,
            targetLanguage: TargetLanguageOption,
            captionDisplayMode: RealtimeCaptionDisplayMode,
            importedAudioURL: URL? = nil,
            serializesMOSS: Bool = false
        ) async throws {
            await stop()
            let uniqueConfigurations = try Self.validated(configurations)
            let hasMOSS = uniqueConfigurations.contains {
                $0.recognitionModel.runtime == .mossOffline
            }
            let sessionID = UUID()
            activeSessionID = sessionID
            self.configurations = uniqueConfigurations
            self.primaryLaneID = uniqueConfigurations.contains(where: { $0.id == primaryLaneID })
                ? primaryLaneID
                : uniqueConfigurations[0].id
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.captionDisplayMode = captionDisplayMode
            audioSource = importedAudioURL == nil ? nil : .importedAudio
            deferredMOSSURL = serializesMOSS && hasMOSS ? importedAudioURL : nil
            startedAt = nil
            pausedAt = nil
            pausedDuration = 0
            completedTracks = []
            recognitionLagBreachCounts = [:]
            didEncounterSustainedRecognitionLag = false
            didEncounterCriticalMemoryPressure = false

            do {
                for model in distinctModels(in: uniqueConfigurations) where model.runtime != .mossOffline {
                    try await startRecognitionNode(model: model, sessionID: sessionID)
                }
                if hasMOSS, importedAudioURL == nil {
                    throw RealtimeRecognizerError.unsupportedModel(
                        RecognitionModelDescriptor.mossTranscribeDiarize.id
                    )
                }
            } catch {
                await stopNodes()
                laneRuntimes.removeAll()
                self.configurations = []
                throw error
            }

            startedAt = Date()
            for configuration in uniqueConfigurations {
                installLaneRuntime(configuration, startedOffset: 0)
            }
            isRunning = true
            updateFanout()
            for runtime in laneRuntimes.values {
                runtime.markListening()
            }
            if let importedAudioURL,
               hasMOSS,
               !serializesMOSS
            {
                startMOSSRecognition(url: importedAudioURL, sessionID: sessionID)
            }
            publishSnapshots()
        }

        func addLane(_ configuration: RealtimeLaneConfiguration) async throws {
            guard !isUnderMemoryPressure else {
                throw RealtimePipelineError.memoryPressure
            }
            guard configurations.count < Self.maximumLaneCount else {
                throw RealtimePipelineError.maximumLaneCount
            }
            guard !configurations.contains(where: {
                $0.recognitionModelID == configuration.recognitionModelID &&
                    $0.translationProvider == configuration.translationProvider
            }) else {
                throw RealtimePipelineError.duplicateLane
            }
            _ = try Self.validated(configurations + [configuration])

            var createdRecognitionNode = false
            if isRunning {
                let model = configuration.recognitionModel
                createdRecognitionNode = recognitionNodes[model.id] == nil
                if recognitionNodes[model.id] == nil {
                    try await startRecognitionNode(model: model, sessionID: activeSessionID)
                }
            }

            let activationOffset = audioFanout.currentAudioOffset
            let recognitionBaseline = recognitionNodes[configuration.recognitionModel.id]?.currentRecognitionSnapshot
            if createdRecognitionNode {
                recognitionNodes[configuration.recognitionModel.id]?.setTimelineBaseOffset(activationOffset)
            }
            configurations.append(configuration)
            installLaneRuntime(
                configuration,
                startedOffset: activationOffset,
                recognitionBaseline: recognitionBaseline
            )
            updateFanout()
            laneRuntimes[configuration.id]?.markListening()
            publishSnapshots()
        }

        func removeLane(id: UUID) async {
            guard configurations.count > 1,
                  let configuration = configurations.first(where: { $0.id == id })
            else {
                return
            }

            await removeSubscriber(id, modelID: configuration.recognitionModel.id)
            if let runtime = laneRuntimes[id] {
                await runtime.stop()
                let track = runtime.trackSnapshot()
                if !track.segments.isEmpty {
                    completedTracks.append(track)
                }
            }
            laneRuntimes.removeValue(forKey: id)
            configurations.removeAll { $0.id == id }
            if primaryLaneID == id {
                primaryLaneID = configurations.first?.id
            }
            updateFanout()
            publishSnapshots()
        }

        func setPrimaryLaneID(_ id: UUID) {
            guard configurations.contains(where: { $0.id == id }) else { return }
            primaryLaneID = id
            publishSnapshots()
        }

        func updateCaptionDisplayMode(_ mode: RealtimeCaptionDisplayMode) {
            captionDisplayMode = mode
            for runtime in laneRuntimes.values {
                runtime.refreshPresentation()
            }
            publishSnapshots()
        }

        func setPaused(_ isPaused: Bool) {
            if isPaused {
                pausedAt = Date()
            } else if let pausedAt {
                pausedDuration += Date().timeIntervalSince(pausedAt)
                self.pausedAt = nil
            }
            audioFanout.setPaused(isPaused)
            for node in recognitionNodes.values {
                node.setPaused(isPaused)
            }
            for runtime in laneRuntimes.values {
                runtime.setPaused(isPaused)
            }
        }

        func stop() async {
            guard isRunning || !recognitionNodes.isEmpty else {
                reset()
                return
            }
            isStopping = true
            audioFanout.update(recognitionNodes: [])
            mossTask?.cancel()
            await stopNodes()
            await mossTask?.value
            mossTask = nil
            for runtime in laneRuntimes.values {
                await runtime.stop()
            }
            activeSessionID = UUID()
            isRunning = false
            isStopping = false
            publishSnapshots()
        }

        func reset() {
            audioFanout.update(recognitionNodes: [])
            configurations = []
            primaryLaneID = nil
            recognitionNodes = [:]
            recognitionSubscribers = [:]
            laneRuntimes = [:]
            completedTracks = []
            activeSessionID = UUID()
            startedAt = nil
            pausedAt = nil
            pausedDuration = 0
            isRunning = false
            isStopping = false
            recognitionLagBreachCounts = [:]
            didEncounterSustainedRecognitionLag = false
            audioSource = nil
            mossTask?.cancel()
            mossTask = nil
            deferredMOSSURL = nil
            publishSnapshots()
        }

        nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
            audioFanout.append(sampleBuffer)
        }

        nonisolated func append(_ pcmBuffer: AVAudioPCMBuffer) {
            audioFanout.append(pcmBuffer)
        }

        func finishImportedAudioInputAndWaitForOfflineRecognition() async {
            if let deferredMOSSURL {
                self.deferredMOSSURL = nil
                audioFanout.update(recognitionNodes: [])
                await stopInputNodesPreservingSubscribers()
                startMOSSRecognition(url: deferredMOSSURL, sessionID: activeSessionID)
            }
            await mossTask?.value
        }
    }
#endif
