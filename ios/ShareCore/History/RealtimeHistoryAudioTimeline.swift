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

        /// Loudness envelope of the whole recording timeline, normalized to 0...1. Each bucket covers
        /// `duration / bucketCount` seconds; gaps between audio segments stay silent.
        public static func waveformLevels(
            for recording: RealtimeHistoryAudioRecording,
            bucketCount: Int
        ) async throws -> [Float] {
            let totalDuration = duration(for: recording)
            guard totalDuration > 0, bucketCount > 0 else { return [] }
            var sumOfSquares = [Double](repeating: 0, count: bucketCount)
            var sampleCounts = [Int](repeating: 0, count: bucketCount)

            for segment in recording.segments.sorted(by: { $0.offset < $1.offset }) {
                try Task.checkCancellation()
                guard let url = RealtimeHistoryAudioStorage.fileURL(for: segment),
                      FileManager.default.fileExists(atPath: url.path)
                else {
                    throw RealtimeHistoryAudioTimelineError.missingAudioFile(segment.relativePath)
                }
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let bucketsPerFrame = Double(bucketCount) / (totalDuration * format.sampleRate)
                let firstFrame = segment.offset * format.sampleRate
                var framesRead: AVAudioFramePosition = 0

                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let frameCount = min(readFrameCapacity, AVAudioFrameCount(file.length - file.framePosition))
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                        throw RealtimeHistoryAudioTimelineError.conversionUnavailable
                    }
                    try file.read(into: buffer, frameCount: frameCount)
                    let length = Int(buffer.frameLength)
                    guard length > 0, let channels = buffer.floatChannelData else { break }
                    let channelCount = Int(format.channelCount)
                    for frame in 0 ..< length {
                        var sample: Float = 0
                        for channel in 0 ..< channelCount {
                            sample = max(sample, abs(channels[channel][frame]))
                        }
                        let position = (firstFrame + Double(framesRead + AVAudioFramePosition(frame))) * bucketsPerFrame
                        let bucket = min(bucketCount - 1, max(0, Int(position)))
                        sumOfSquares[bucket] += Double(sample * sample)
                        sampleCounts[bucket] += 1
                    }
                    framesRead += AVAudioFramePosition(length)
                }
            }

            let levels = zip(sumOfSquares, sampleCounts).map { sum, count in
                count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
            }
            guard let loudest = levels.max(), loudest > 0 else { return levels }
            // A mild curve keeps quiet speech visible without flattening loud passages.
            return levels.map { pow($0 / loudest, 0.8) }
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
