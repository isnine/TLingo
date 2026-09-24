#if os(macOS)
    import Foundation
    import os

    @MainActor
    extension RealtimePipelineCoordinator {
        func startRecognitionNode(
            model: RecognitionModelDescriptor,
            sessionID: UUID
        ) async throws {
            let node = RealtimeRecognitionNode(model: model)
            node.onResult = { [weak self] callbackSessionID, result in
                guard let self else { return }
                self.callbackDrain.enter()
                Task { @MainActor in
                    defer { self.callbackDrain.leave() }
                    self.receiveRecognition(
                        modelID: model.id,
                        sessionID: callbackSessionID,
                        result: result
                    )
                }
            }
            node.onFailure = { [weak self] callbackSessionID, error in
                guard let self else { return }
                self.callbackDrain.enter()
                Task { @MainActor in
                    defer { self.callbackDrain.leave() }
                    self.receiveRecognitionFailure(
                        modelID: model.id,
                        sessionID: callbackSessionID,
                        error: error
                    )
                }
            }
            try await node.start(
                locale: sourceLanguage == .auto
                    ? Locale(
                        identifier: model == .nemotronMultilingual2240 || model == .confuciusR2T2 ? "und" : "en-US"
                    )
                    : Locale(identifier: sourceLanguage.rawValue),
                sessionID: sessionID,
                timelineBaseOffset: isRunning ? audioFanout.currentAudioOffset : 0
            )
            recognitionNodes[model.id] = node
            if recognitionSubscribers[model.id] == nil {
                recognitionSubscribers[model.id] = []
            }
        }

        func installLaneRuntime(
            _ configuration: RealtimeLaneConfiguration,
            startedOffset: TimeInterval,
            recognitionBaseline: RealtimeRecognitionSnapshot? = nil
        ) {
            let runtime = RealtimeLaneRuntime(
                configuration: configuration,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                audioSource: audioSource,
                startedOffset: startedOffset,
                recognitionBaseline: recognitionBaseline,
                displayMode: { [weak self] in self?.captionDisplayMode ?? .bilingual },
                elapsed: { [weak self] in self?.audioFanout.currentAudioOffset ?? startedOffset }
            )
            runtime.onChange = { [weak self] in
                self?.publishSnapshots()
            }
            laneRuntimes[configuration.id] = runtime
            recognitionSubscribers[configuration.recognitionModel.id, default: []].insert(configuration.id)
            realtimePipelineLogger.info(
                """
                lane installed id=\(configuration.id.uuidString, privacy: .public) \
                model=\(configuration.recognitionModel.id, privacy: .public) \
                references=\(self.recognitionSubscribers[configuration.recognitionModel.id]?.count ?? 0)
                """
            )
        }

        func startMOSSRecognition(url: URL, sessionID: UUID) {
            #if arch(arm64) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
                mossTask = Task { [weak self] in
                    do {
                        let segments = try await RealtimeHistoryMOSSReconstructor.shared.recognizeImportedAudio(
                            at: url
                        ) { progress in
                            switch progress {
                            case .loadingModel, .preparingAudio, .transcribing:
                                for laneID in self?.recognitionSubscribers[
                                    RecognitionModelDescriptor.mossTranscribeDiarize.id
                                ] ?? [] {
                                    self?.laneRuntimes[laneID]?.markRecognizing()
                                }
                            case .downloading, .translating:
                                break
                            }
                        }
                        try Task.checkCancellation()
                        let result = RealtimeRecognitionResult(snapshot: RealtimeRecognitionSnapshot(
                            stableSegments: segments,
                            audioOffset: segments.last?.endOffset,
                            isTerminal: true
                        ))
                        self?.receiveRecognition(
                            modelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                            sessionID: sessionID,
                            result: result
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.receiveRecognitionFailure(
                            modelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                            sessionID: sessionID,
                            error: error
                        )
                    }
                }
            #else
                receiveRecognitionFailure(
                    modelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
                    sessionID: sessionID,
                    error: RealtimeRecognizerError.unsupportedModel(
                        RecognitionModelDescriptor.mossTranscribeDiarize.id
                    )
                )
            #endif
        }

        func receiveRecognition(
            modelID: String,
            sessionID: UUID,
            result: RealtimeRecognitionResult
        ) {
            guard sessionID == activeSessionID else { return }
            if !isStopping, let audioOffset = result.audioOffset {
                let lag = max(0, audioFanout.currentAudioOffset - audioOffset)
                recognitionLagBreachCounts[modelID] = lag > 5
                    ? recognitionLagBreachCounts[modelID, default: 0] + 1
                    : 0
                if recognitionLagBreachCounts[modelID, default: 0] >= 3 {
                    didEncounterSustainedRecognitionLag = true
                    realtimePipelineLogger.warning(
                        "recognition lag model=\(modelID, privacy: .public) seconds=\(lag)"
                    )
                }
            }
            for laneID in recognitionSubscribers[modelID] ?? [] {
                laneRuntimes[laneID]?.receiveRecognition(result)
            }
        }

        func receiveRecognitionFailure(
            modelID: String,
            sessionID: UUID,
            error: Error
        ) {
            guard sessionID == activeSessionID else { return }
            let laneIDs = recognitionSubscribers[modelID] ?? []
            for laneID in laneIDs {
                laneRuntimes[laneID]?.fail(error)
            }
            onFailure?(laneIDs.first, error)
        }

        func removeSubscriber(_ laneID: UUID, modelID: String) async {
            guard let subscribers = recognitionSubscribers[modelID] else { return }
            if subscribers.count > 1 {
                recognitionSubscribers[modelID]?.remove(laneID)
                realtimePipelineLogger.info(
                    """
                    recognition node model=\(modelID, privacy: .public) \
                    references=\(self.recognitionSubscribers[modelID]?.count ?? 0)
                    """
                )
                return
            }

            let node = recognitionNodes.removeValue(forKey: modelID)
            audioFanout.update(recognitionNodes: Array(recognitionNodes.values))
            await node?.stop()
            await callbackDrain.wait()
            recognitionSubscribers[modelID]?.remove(laneID)
            let referenceCount = recognitionSubscribers[modelID]?.count ?? 0
            realtimePipelineLogger.info(
                "recognition node model=\(modelID, privacy: .public) references=\(referenceCount)"
            )
            recognitionSubscribers.removeValue(forKey: modelID)
        }

        func updateFanout() {
            audioFanout.update(recognitionNodes: Array(recognitionNodes.values))
        }

        func stopNodes() async {
            let recognitionNodes = Array(recognitionNodes.values)
            for node in recognitionNodes {
                await node.stop()
            }
            await callbackDrain.wait()
            self.recognitionNodes = [:]
            recognitionSubscribers = [:]
        }

        func stopInputNodesPreservingSubscribers() async {
            let recognitionNodes = Array(recognitionNodes.values)
            for node in recognitionNodes {
                await node.stop()
            }
            await callbackDrain.wait()
            self.recognitionNodes = [:]
        }

        func elapsed() -> TimeInterval {
            guard let startedAt else { return 0 }
            return max(0, (pausedAt ?? Date()).timeIntervalSince(startedAt) - pausedDuration)
        }

        func distinctModels(
            in configurations: [RealtimeLaneConfiguration]
        ) -> [RecognitionModelDescriptor] {
            let modelIDs = Self.distinctRecognitionModelIDs(in: configurations)
            return modelIDs.map { RecognitionModelStore.selectableDescriptor(forModelID: $0) }
        }

        func publishSnapshots() {
            onSnapshotsChanged?(snapshots)
        }

        func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) async {
            if event.contains(.normal) {
                realtimePipelineLogger.info("memory pressure returned to normal")
                if isUnderMemoryPressure {
                    isUnderMemoryPressure = false
                    onMemoryPressureChanged?(false)
                }
                return
            }
            if event.contains(.warning) || event.contains(.critical) {
                realtimePipelineLogger.warning(
                    "memory pressure event=\(event.rawValue, privacy: .public)"
                )
                if !isUnderMemoryPressure {
                    isUnderMemoryPressure = true
                    onMemoryPressureChanged?(true)
                }
            }
            guard event.contains(.critical) else { return }
            didEncounterCriticalMemoryPressure = true
            guard let candidate = configurations.reversed().first(where: {
                $0.id != primaryLaneID && $0.recognitionModel.runtime == .fluidAudio
            }) else {
                return
            }
            await removeLane(id: candidate.id)
            let message = String(
                localized: "\(candidate.recognitionModel.title) stopped because the Mac reported critical memory pressure."
            )
            onLaneTerminated?(candidate.id, message)
        }
    }
#endif
