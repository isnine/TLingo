#if os(macOS) || os(iOS)
    import AVFoundation
    import Foundation

    public enum RealtimeHistoryAudioTimeline {
        private static let sampleRate = 16000.0
        private static let readFrameCapacity: AVAudioFrameCount = 4096

        public static func duration(for recording: RealtimeHistoryAudioRecording) -> TimeInterval {
            recording.segments.map { $0.offset + $0.duration }.max() ?? 0
        }

        public static func composition(for recording: RealtimeHistoryAudioRecording) async throws -> AVMutableComposition {
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw RealtimeHistoryAudioTimelineError.compositionUnavailable
            }

            for segment in recording.segments.sorted(by: { $0.offset < $1.offset }) {
                try Task.checkCancellation()
                guard let url = RealtimeHistoryAudioStorage.fileURL(for: segment),
                      FileManager.default.fileExists(atPath: url.path)
                else {
                    throw RealtimeHistoryAudioTimelineError.missingAudioFile(segment.relativePath)
                }
                let asset = AVURLAsset(url: url)
                guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw RealtimeHistoryAudioTimelineError.unreadableAudioFile(segment.relativePath)
                }
                let duration = try await asset.load(.duration)
                try compositionTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: assetTrack,
                    at: CMTime(seconds: segment.offset, preferredTimescale: 600)
                )
            }
            return composition
        }

        public static func makeTemporaryPCMFile(
            for recording: RealtimeHistoryAudioRecording
        ) async throws -> URL {
            guard let converter = RealtimePCMBufferConverter(
                sampleRate: sampleRate,
                channels: 1,
                commonFormat: .pcmFormatFloat32
            ) else {
                throw RealtimeHistoryAudioTimelineError.conversionUnavailable
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TLingo-MOSS-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            let outputFile = try AVAudioFile(
                forWriting: url,
                settings: converter.targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            for segment in recording.segments.sorted(by: { $0.offset < $1.offset }) {
                try Task.checkCancellation()
                guard let sourceURL = RealtimeHistoryAudioStorage.fileURL(for: segment),
                      FileManager.default.fileExists(atPath: sourceURL.path)
                else {
                    throw RealtimeHistoryAudioTimelineError.missingAudioFile(segment.relativePath)
                }

                let targetFrame = AVAudioFramePosition((segment.offset * sampleRate).rounded())
                if outputFile.framePosition < targetFrame {
                    try writeSilence(
                        frameCount: AVAudioFrameCount(targetFrame - outputFile.framePosition),
                        format: converter.targetFormat,
                        to: outputFile
                    )
                }

                let inputFile = try AVAudioFile(forReading: sourceURL)
                while inputFile.framePosition < inputFile.length {
                    try Task.checkCancellation()
                    let frameCount = min(
                        readFrameCapacity,
                        AVAudioFrameCount(inputFile.length - inputFile.framePosition)
                    )
                    guard let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFile.processingFormat,
                        frameCapacity: frameCount
                    ) else {
                        throw RealtimeHistoryAudioTimelineError.conversionUnavailable
                    }
                    try inputFile.read(into: inputBuffer, frameCount: frameCount)
                    guard inputBuffer.frameLength > 0 else { break }
                    guard let outputBuffer = converter.pcmBuffer(from: inputBuffer) else {
                        throw RealtimeHistoryAudioTimelineError.conversionUnavailable
                    }
                    try outputFile.write(from: outputBuffer)
                }
            }
            return url
        }

        private static func writeSilence(
            frameCount: AVAudioFrameCount,
            format: AVAudioFormat,
            to outputFile: AVAudioFile
        ) throws {
            var remaining = frameCount
            while remaining > 0 {
                let count = min(remaining, readFrameCapacity)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    throw RealtimeHistoryAudioTimelineError.conversionUnavailable
                }
                buffer.frameLength = count
                if let channelData = buffer.floatChannelData {
                    channelData[0].initialize(repeating: 0, count: Int(count))
                }
                try outputFile.write(from: buffer)
                remaining -= count
            }
        }
    }

    public enum RealtimeHistoryAudioTimelineError: LocalizedError, Equatable {
        case compositionUnavailable
        case conversionUnavailable
        case missingAudioFile(String)
        case unreadableAudioFile(String)

        public var errorDescription: String? {
            switch self {
            case .compositionUnavailable:
                return String(localized: "The audio timeline could not be created.")
            case .conversionUnavailable:
                return String(localized: "The recording audio could not be converted.")
            case let .missingAudioFile(path):
                return String(localized: "The recording audio file is missing: \(path)")
            case let .unreadableAudioFile(path):
                return String(localized: "The recording audio file could not be read: \(path)")
            }
        }
    }
#endif
