#if (DEBUG || TLINGO_LOCAL_DEVICE_BENCHMARK) && os(iOS) && arch(arm64) && canImport(FluidAudio)
    import AVFoundation
    import Darwin
    import Foundation
    import QuartzCore

    enum DeviceRealtimeBenchmark {
        struct Sample: Encodable {
            let wallSeconds: Double
            let inputAudioSeconds: Double
            let processedAudioSeconds: Double
            let pendingChunks: Int
            let footprintMiB: Double?
            let transcriptCharacters: Int
            let stableSegments: Int
            let thermalState: Int
        }

        struct Report: Encodable {
            let modelID: String
            let modelWasCached: Bool
            let downloadMs: Double?
            let engineLoadMs: Double
            let audioFileSeconds: Double
            let audioSeconds: Double
            let firstNonemptyRecognitionMs: Double
            let maxBacklogSeconds: Double
            let maxPendingChunks: Int
            let drainMs: Double
            let finalizeMs: Double
            let finalTranscriptCharacters: Int
            let footprintAfterStopMiB: Double?
            let samples: [Sample]
        }

        struct LifecycleReport: Encodable {
            let footprintBeforeLoadMiB: Double?
            let initial: Report
            let restart: Report
            let footprintAfterPurgeMiB: Double?
        }

        static func runLifecycle(modelID: String, seconds: Int, allowsDownload: Bool) async throws -> LifecycleReport {
            let baseline = footprintMiB()
            let initial = try await run(modelID: modelID, seconds: seconds, allowsDownload: allowsDownload)
            let restart = try await run(modelID: modelID, seconds: seconds, allowsDownload: false)
            await RealtimeFluidAudioEngineCache.shared.purge(reason: "benchmark")
            try await Task.sleep(for: .seconds(2))
            return LifecycleReport(
                footprintBeforeLoadMiB: baseline, initial: initial, restart: restart,
                footprintAfterPurgeMiB: footprintMiB()
            )
        }

        static func run(modelID: String, seconds: Int, allowsDownload: Bool) async throws -> Report {
            let sampleRate = 16000.0
            let url = URL.documentsDirectory.appendingPathComponent("debug-realtime-fixture.wav")
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
            guard file.processingFormat.sampleRate == sampleRate, file.processingFormat.channelCount == 1, file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5120)
            else {
                throw DevicePerformanceError("Use a nonempty mono 16 kHz WAV file.")
            }
            guard let model = RecognitionModelStore.availableModels
                .first(where: { $0.id == modelID && $0.runtime == .fluidAudio })
            else {
                throw DevicePerformanceError("Choose a supported FluidAudio realtime model.")
            }
            let store = RecognitionModelStore.shared
            let cached = await store.isModelCached(model)
            var downloadMs: Double?
            if !cached {
                guard allowsDownload else { throw DevicePerformanceError("Model is not cached; download was not enabled.") }
                let downloadStart = CACurrentMediaTime()
                try await withTaskCancellationHandler {
                    try await store.downloadModel(model)
                } onCancel: {
                    Task { await store.cancelDownload(model) }
                }
                downloadMs = (CACurrentMediaTime() - downloadStart) * 1000
            }
            let collector = Collector()
            let recognizer = RealtimeFluidAudioRecognizer(delegate: collector)
            let loadStart = CACurrentMediaTime()
            try await recognizer.start(model: model, locale: Locale(identifier: "en-US"), sessionID: UUID())
            let loadMs = (CACurrentMediaTime() - loadStart) * 1000
            let clock = ContinuousClock()
            let audioStart = clock.now
            let wallStart = CACurrentMediaTime()
            var samples = [sample(recognizer, collector: collector, since: wallStart)]
            var suppliedFrames: AVAudioFramePosition = 0
            var maxBacklog = 0.0
            var maxPending = 0
            var nextSample = 15.0
            let totalFrames = AVAudioFramePosition(Double(seconds) * sampleRate)
            let drainMs: Double
            do {
                while suppliedFrames < totalFrames {
                    try Task.checkCancellation()
                    try collector.checkError()
                    if file.framePosition == file.length {
                        file.framePosition = 0
                    }
                    let remaining = min(totalFrames - suppliedFrames, file.length - file.framePosition)
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 5120)))
                    guard buffer.frameLength > 0 else { throw DevicePerformanceError("Audio fixture stopped producing samples.") }
                    suppliedFrames += AVAudioFramePosition(buffer.frameLength)
                    let elapsed = Double(suppliedFrames) / sampleRate
                    try await clock.sleep(until: audioStart.advanced(by: .seconds(elapsed)))
                    recognizer.append(buffer)
                    let diagnostics = recognizer.diagnostics
                    maxBacklog = max(maxBacklog, diagnostics.inputAudioOffset - diagnostics.processedAudioOffset)
                    maxPending = max(maxPending, diagnostics.pendingChunkCount)
                    if elapsed >= nextSample {
                        samples.append(sample(recognizer, collector: collector, since: wallStart))
                        nextSample += 15
                    }
                }
                let drainStart = CACurrentMediaTime()
                while recognizer.diagnostics.processedAudioOffset < Double(seconds) {
                    try collector.checkError()
                    guard CACurrentMediaTime() - drainStart < 30 else {
                        throw DevicePerformanceError("Timed out draining recognition audio.")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                drainMs = (CACurrentMediaTime() - drainStart) * 1000
                samples.append(sample(recognizer, collector: collector, since: wallStart))
            } catch {
                await recognizer.stop()
                throw error
            }
            let finalizeStart = CACurrentMediaTime()
            await recognizer.stop()
            let finalizeMs = (CACurrentMediaTime() - finalizeStart) * 1000
            try collector.checkError()
            let final = collector.snapshot
            guard let firstText = final.firstTextAt else { throw DevicePerformanceError("No nonempty speech result.") }
            return Report(
                modelID: model.id, modelWasCached: cached, downloadMs: downloadMs, engineLoadMs: loadMs,
                audioFileSeconds: Double(file.length) / sampleRate, audioSeconds: Double(seconds),
                firstNonemptyRecognitionMs: (firstText - wallStart) * 1000,
                maxBacklogSeconds: maxBacklog, maxPendingChunks: maxPending,
                drainMs: drainMs, finalizeMs: finalizeMs,
                finalTranscriptCharacters: final.latest?.visibleText.count ?? 0,
                footprintAfterStopMiB: footprintMiB(), samples: samples
            )
        }

        private static func sample(
            _ recognizer: RealtimeFluidAudioRecognizer, collector: Collector, since start: Double
        ) -> Sample {
            let diagnostics = recognizer.diagnostics
            let latest = collector.snapshot.latest
            return Sample(
                wallSeconds: CACurrentMediaTime() - start,
                inputAudioSeconds: diagnostics.inputAudioOffset, processedAudioSeconds: diagnostics.processedAudioOffset,
                pendingChunks: diagnostics.pendingChunkCount, footprintMiB: footprintMiB(),
                transcriptCharacters: latest?.visibleText.count ?? 0, stableSegments: latest?.stableSegments.count ?? 0,
                thermalState: ProcessInfo.processInfo.thermalState.rawValue
            )
        }

        private static func footprintMiB() -> Double? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
        }

        private final class Collector: RealtimeFluidAudioRecognizerDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private var latest: RealtimeRecognitionSnapshot?
            private var firstTextAt: Double?
            private var failure: Error?

            var snapshot: (latest: RealtimeRecognitionSnapshot?, firstTextAt: Double?) {
                lock.withLock { (latest, firstTextAt) }
            }

            func checkError() throws {
                if let error = lock.withLock({ failure }) {
                    throw error
                }
            }

            func realtimeFluidAudioRecognizer(
                _: RealtimeFluidAudioRecognizer, sessionID _: UUID, didRecognize result: RealtimeRecognitionResult
            ) {
                guard let snapshot = result.snapshot else { return }
                lock.withLock {
                    latest = snapshot
                    if firstTextAt == nil, !snapshot.stableText.isEmpty || !snapshot.volatileText.isEmpty {
                        firstTextAt = CACurrentMediaTime()
                    }
                }
            }

            func realtimeFluidAudioRecognizer(_: RealtimeFluidAudioRecognizer, sessionID _: UUID, didFail error: Error) {
                lock.withLock { failure = error }
            }
        }
    }
#endif
