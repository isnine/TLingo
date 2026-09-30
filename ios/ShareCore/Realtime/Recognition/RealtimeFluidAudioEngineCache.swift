#if (os(macOS) || os(iOS)) && arch(arm64) && canImport(FluidAudio)
    import FluidAudio
    import Foundation
    #if os(iOS)
        import UIKit
    #endif

    /// Keeps at most one loaded FluidAudio engine outside a session. Loading is dominated by the
    /// CoreML encoder's Neural Engine compile and can take many seconds, so the realtime page
    /// prewarms the selected model and a stopped session hands its engine back for the next start.
    actor RealtimeFluidAudioEngineCache {
        static let shared = RealtimeFluidAudioEngineCache()

        private static let loadDurationsKey = "realtimeFluidAudioLoadDurations"

        private struct Slot {
            let id: UUID
            let model: RecognitionFluidAudioModel
            let startedAt: Date
            let task: Task<RealtimeFluidAudioStreamingEngine, Error>
            var isReady: Bool
        }

        private var slot: Slot?
        private var isInBackground = false
        private var memoryPressureSource: DispatchSourceMemoryPressure?
        private var observers: [NSObjectProtocol] = []

        func prewarm(_ descriptor: RecognitionModelDescriptor) {
            installObserversIfNeeded()
            guard !isInBackground, let model = Self.fluidAudioModel(descriptor) else { return }
            guard slot?.model != model else { return }
            slot = startLoading(model, descriptor: descriptor)
            RealtimeLog.log("fluid", "prewarm started model=\(model.rawValue)")
        }

        /// Nil when the model is already loaded; otherwise when its load began (or would begin now)
        /// plus the last measured load time for this model.
        func loadProgress(for descriptor: RecognitionModelDescriptor) -> RealtimeModelLoadProgress? {
            guard let model = Self.fluidAudioModel(descriptor) else { return nil }
            if let slot, slot.model == model {
                return slot.isReady ? nil : RealtimeModelLoadProgress(
                    startedAt: slot.startedAt,
                    estimatedDuration: Self.recordedLoadDuration(for: model)
                )
            }
            return RealtimeModelLoadProgress(
                startedAt: Date(),
                estimatedDuration: Self.recordedLoadDuration(for: model)
            )
        }

        /// Takes the warm (or still loading) engine when it matches; otherwise loads a fresh one.
        /// The caller owns the engine until it calls `checkIn`.
        func checkOut(_ descriptor: RecognitionModelDescriptor) async throws -> RealtimeFluidAudioStreamingEngine {
            installObserversIfNeeded()
            guard let model = Self.fluidAudioModel(descriptor) else {
                throw RealtimeRecognizerError.unsupportedModel(descriptor.id)
            }
            if let current = slot, current.model == model {
                slot = nil
                if let engine = try? await current.task.value {
                    RealtimeLog.log("fluid", "engine reused model=\(model.rawValue) warm=\(current.isReady)")
                    return engine
                }
                // A failed prewarm falls through to a fresh load so its error surfaces from this start.
            } else {
                slot = nil
            }
            return try await startLoading(model, descriptor: descriptor).task.value
        }

        /// Keeps a reset engine for the next start unless another model already occupies the slot.
        func checkIn(_ engine: RealtimeFluidAudioStreamingEngine, model: RecognitionFluidAudioModel) {
            guard !isInBackground, slot == nil else { return }
            slot = Slot(id: UUID(), model: model, startedAt: Date(), task: Task { engine }, isReady: true)
        }

        func purge(reason: String) {
            guard let slot else { return }
            RealtimeLog.log("fluid", "engine released model=\(slot.model.rawValue) reason=\(reason)")
            self.slot = nil
        }

        private func startLoading(_ model: RecognitionFluidAudioModel, descriptor: RecognitionModelDescriptor) -> Slot {
            let id = UUID()
            let startedAt = Date()
            let task = Task {
                let engine = try await Self.load(model, descriptor: descriptor)
                await self.didFinishLoading(id: id, model: model, duration: Date().timeIntervalSince(startedAt))
                return engine
            }
            return Slot(id: id, model: model, startedAt: startedAt, task: task, isReady: false)
        }

        private func didFinishLoading(id: UUID, model: RecognitionFluidAudioModel, duration: TimeInterval) {
            RealtimeLog.log("fluid", "model loaded model=\(model.rawValue) loadMs=\(Int(duration * 1000))")
            Self.recordLoadDuration(duration, for: model)
            if slot?.id == id {
                slot?.isReady = true
            }
        }

        private func setInBackground(_ isInBackground: Bool) {
            self.isInBackground = isInBackground
            if isInBackground {
                purge(reason: "background")
            }
        }

        private func installObserversIfNeeded() {
            guard memoryPressureSource == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
            source.setEventHandler { [weak self] in
                Task { await self?.purge(reason: "memoryPressure") }
            }
            source.resume()
            memoryPressureSource = source
            #if os(iOS)
                let center = NotificationCenter.default
                observers = [
                    center.addObserver(
                        forName: UIApplication.didEnterBackgroundNotification,
                        object: nil,
                        queue: nil
                    ) { [weak self] _ in
                        Task { await self?.setInBackground(true) }
                    },
                    center.addObserver(
                        forName: UIApplication.willEnterForegroundNotification,
                        object: nil,
                        queue: nil
                    ) { [weak self] _ in
                        Task { await self?.setInBackground(false) }
                    },
                ]
            #endif
        }

        private static func fluidAudioModel(_ descriptor: RecognitionModelDescriptor) -> RecognitionFluidAudioModel? {
            guard descriptor.runtime == .fluidAudio, case let .fluidAudio(model) = descriptor.download else {
                return nil
            }
            return model
        }

        private static func recordedLoadDuration(for model: RecognitionFluidAudioModel) -> TimeInterval? {
            let durations = UserDefaults.standard.dictionary(forKey: loadDurationsKey) as? [String: Double]
            return durations?[model.rawValue]
        }

        private static func recordLoadDuration(_ duration: TimeInterval, for model: RecognitionFluidAudioModel) {
            var durations = UserDefaults.standard.dictionary(forKey: loadDurationsKey) as? [String: Double] ?? [:]
            durations[model.rawValue] = duration
            UserDefaults.standard.set(durations, forKey: loadDurationsKey)
        }

        private static func load(
            _ model: RecognitionFluidAudioModel,
            descriptor: RecognitionModelDescriptor
        ) async throws -> RealtimeFluidAudioStreamingEngine {
            let modelDirectory = await RecognitionModelStore.shared.cachedModelURL(for: descriptor)
            switch model {
            case .parakeetEOU320, .parakeetEOU1280:
                let manager = StreamingEouAsrManager(
                    chunkSize: model == .parakeetEOU320 ? .ms320 : .ms1280
                )
                try await manager.loadModels(to: modelDirectory)
                return .eou(manager)
            case .nemotronStreaming560, .nemotronStreaming1120, .nemotronStreaming2240:
                let chunkSize: NemotronChunkSize = switch model {
                case .nemotronStreaming560: .ms560
                case .nemotronStreaming1120: .ms1120
                default: .ms2240
                }
                let manager = StreamingNemotronAsrManager(requestedChunkSize: chunkSize)
                try await manager.loadModels(
                    from: modelDirectory.appendingPathComponent(chunkSize.repo.folderName, isDirectory: true)
                )
                return .standard(manager)
            case .nemotronMultilingual2240:
                let variantDirectory = modelDirectory
                    .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
                    .appendingPathComponent("multilingual/2240ms", isDirectory: true)
                let manager = StreamingNemotronMultilingualAsrManager()
                try await manager.loadModels(from: variantDirectory)
                return .multilingual(manager)
            }
        }
    }
#endif
