#if os(macOS)
    import AVFoundation
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("Realtime imported audio reader")
    struct RealtimeImportedAudioReaderTests {
        @Test("Reads every frame from an imported audio file")
        func readsEveryFrame() async throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TLingo-Imported-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            ))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
                buffer.frameLength = 1600
                try file.write(from: buffer)
            }
            let collector = FrameCollector()

            try await RealtimeImportedAudioReader.run(
                url: url,
                isPaused: { false },
                onBuffer: { collector.append(Int($0.frameLength)) }
            )

            #expect(collector.frameCount == 1600)
        }
    }

    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0

        var frameCount: Int {
            lock.withLock { frames }
        }

        func append(_ count: Int) {
            lock.withLock {
                frames += count
            }
        }
    }
#endif
