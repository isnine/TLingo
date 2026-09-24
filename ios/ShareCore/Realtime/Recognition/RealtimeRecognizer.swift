#if os(macOS) || os(iOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    protocol RealtimeRecognizer: AnyObject {
        var sampleRate: Int { get }

        func start(model: RecognitionModelDescriptor, locale: Locale, sessionID: UUID) async throws
        func append(_ sampleBuffer: CMSampleBuffer)
        func append(_ pcmBuffer: AVAudioPCMBuffer)
        func setPaused(_ isPaused: Bool)
        func stop() async
    }

    enum RealtimeRecognizerError: LocalizedError {
        case unsupportedModel(String)
        case audioBacklogExceeded
        case audioBufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case let .unsupportedModel(modelID):
                return "Unsupported recognition model: \(modelID)"
            case .audioBacklogExceeded:
                return "Realtime recognition could not keep up with the audio stream."
            case .audioBufferAllocationFailed:
                return "Realtime recognition could not allocate an audio buffer."
            }
        }
    }

    final class RealtimeRecognizerSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var recognizer: (any RealtimeRecognizer)?

        func set(_ recognizer: (any RealtimeRecognizer)?) {
            lock.lock()
            self.recognizer = recognizer
            lock.unlock()
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            let recognizer = currentRecognizer()
            recognizer?.append(sampleBuffer)
        }

        func append(_ pcmBuffer: AVAudioPCMBuffer) {
            let recognizer = currentRecognizer()
            recognizer?.append(pcmBuffer)
        }

        func setPaused(_ isPaused: Bool) {
            let recognizer = currentRecognizer()
            recognizer?.setPaused(isPaused)
        }

        func stop() async {
            let recognizer = takeRecognizer()
            await recognizer?.stop()
        }

        private func currentRecognizer() -> (any RealtimeRecognizer)? {
            lock.lock()
            defer { lock.unlock() }
            return recognizer
        }

        private func takeRecognizer() -> (any RealtimeRecognizer)? {
            lock.lock()
            defer { lock.unlock() }
            let recognizer = recognizer
            self.recognizer = nil
            return recognizer
        }
    }

    final class RealtimeCallbackDrain: @unchecked Sendable {
        private let group = DispatchGroup()

        func enter() {
            group.enter()
        }

        func leave() {
            group.leave()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                group.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume()
                }
            }
        }

        @discardableResult
        func untrackedMainActorTask(
            _ operation: @escaping @MainActor @Sendable () async -> Void
        ) -> Task<Void, Never> {
            Task { @MainActor in
                await operation()
            }
        }
    }

    extension RealtimeLiveSpeechTranscriber: RealtimeRecognizer {
        var sampleRate: Int { RecognitionModelDescriptor.appleSpeech.sampleRate }

        func start(model: RecognitionModelDescriptor, locale: Locale, sessionID: UUID) async throws {
            guard model.runtime == .appleSpeech else {
                throw RealtimeRecognizerError.unsupportedModel(model.id)
            }
            try await start(locale: locale, sessionID: sessionID)
        }
    }
#endif
