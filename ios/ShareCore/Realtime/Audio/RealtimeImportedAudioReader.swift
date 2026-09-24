#if os(macOS)
    import AVFoundation
    import Foundation

    enum RealtimeImportedAudioReader {
        static func run(
            url: URL,
            isPaused: @escaping @Sendable () async -> Bool,
            onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
        ) async throws {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let file = try AVAudioFile(forReading: url)
            let frameCapacity = max(1, AVAudioFrameCount(file.processingFormat.sampleRate / 10))

            while file.framePosition < file.length {
                try Task.checkCancellation()
                if await isPaused() {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }

                let remaining = AVAudioFrameCount(file.length - file.framePosition)
                let frameCount = min(frameCapacity, remaining)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: frameCount
                ) else {
                    throw RealtimeImportedAudioReaderError.bufferAllocationFailed
                }
                try file.read(into: buffer, frameCount: frameCount)
                guard buffer.frameLength > 0 else { break }
                onBuffer(buffer)

                let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                try await Task.sleep(for: .milliseconds(Int((duration * 1000).rounded())))
            }
        }
    }

    enum RealtimeImportedAudioReaderError: LocalizedError {
        case bufferAllocationFailed

        var errorDescription: String? {
            String(localized: "The recording audio file could not be read.")
        }
    }
#endif
