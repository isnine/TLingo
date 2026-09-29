#if os(macOS) || os(iOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    final class RealtimeAudioHistoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private let fileManager: FileManager
        private let segmentDuration: TimeInterval
        private let sampleBufferConverter = RealtimePCMBufferConverter(
            sampleRate: 16000,
            channels: 1,
            commonFormat: .pcmFormatFloat32
        )

        private var recordingID = UUID()
        private var recordingSource: RealtimeHistoryAudioSource = .microphone
        private var directoryName = ""
        private var directoryURL: URL?
        private var segments: [RealtimeHistoryAudioSegment] = []
        private var currentFile: AVAudioFile?
        private var currentFileURL: URL?
        private var currentSegmentIndex = 0
        private var currentSegmentOffset: TimeInterval = 0
        private var currentSegmentFrames: AVAudioFramePosition = 0
        private var currentConverter: AVAudioConverter?
        private var currentConverterInputFormat: AVAudioFormat?
        private var isActive = false
        private var isPaused = false

        init(fileManager: FileManager = .default, segmentDuration: TimeInterval = 5) {
            self.fileManager = fileManager
            self.segmentDuration = segmentDuration
        }

        func start(requestID: UUID, source: RealtimeHistoryAudioSource = .microphone) {
            lock.lock()
            defer { lock.unlock() }

            resetLocked()
            recordingID = UUID()
            recordingSource = source
            directoryName = "\(requestID.uuidString)-\(source.rawValue)"
            guard let directoryURL = RealtimeHistoryAudioStorage.directoryURL(
                for: directoryName,
                fileManager: fileManager
            ) else {
                return
            }
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            self.directoryURL = directoryURL
            isActive = true
        }

        func pause() {
            lock.lock()
            defer { lock.unlock() }

            guard isActive, !isPaused else { return }
            finalizeCurrentSegmentLocked()
            isPaused = true
        }

        func resume() {
            lock.lock()
            defer { lock.unlock() }

            guard isActive else { return }
            isPaused = false
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }

            finalizeCurrentSegmentLocked()
            isActive = false
            isPaused = false
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }

            resetLocked()
        }

        func snapshot() -> RealtimeHistoryAudioRecording? {
            lock.lock()
            defer { lock.unlock() }

            return snapshotLocked()
        }

        @discardableResult
        func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
            lock.lock()
            let canRecord = isActive && !isPaused
            lock.unlock()
            guard canRecord else { return false }
            guard let pcmBuffer = sampleBufferConverter?.pcmBuffer(from: sampleBuffer) else { return false }
            return append(pcmBuffer)
        }

        @discardableResult
        func append(_ pcmBuffer: AVAudioPCMBuffer) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            guard isActive, !isPaused else { return false }
            do {
                if currentFile == nil {
                    try openNextSegmentLocked(format: pcmBuffer.format)
                }
                guard let currentFile else { return false }
                let outputBuffer = try convertedBufferLocked(pcmBuffer, to: currentFile.processingFormat)
                try currentFile.write(from: outputBuffer)
                currentSegmentFrames += AVAudioFramePosition(outputBuffer.frameLength)

                let duration = Double(currentSegmentFrames) / currentFile.processingFormat.sampleRate
                if duration >= segmentDuration {
                    finalizeCurrentSegmentLocked()
                    return true
                }
            } catch {
                RealtimeLog.warn("audio", "history write failed error=\(error.localizedDescription)")
            }
            return false
        }

        private func openNextSegmentLocked(format _: AVAudioFormat) throws {
            guard let directoryURL else { return }
            currentSegmentIndex += 1
            currentSegmentOffset = completedDurationLocked()
            currentSegmentFrames = 0
            currentConverter = nil
            currentConverterInputFormat = nil

            let fileName = String(format: "segment-%04d.m4a", currentSegmentIndex)
            let fileURL = directoryURL.appendingPathComponent(fileName)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,
            ]
            currentFile = try AVAudioFile(forWriting: fileURL, settings: settings)
            currentFileURL = fileURL
        }

        private func convertedBufferLocked(
            _ sourceBuffer: AVAudioPCMBuffer,
            to outputFormat: AVAudioFormat
        ) throws -> AVAudioPCMBuffer {
            if sourceBuffer.format == outputFormat {
                return sourceBuffer
            }

            if currentConverter == nil || currentConverterInputFormat != sourceBuffer.format {
                currentConverter = AVAudioConverter(from: sourceBuffer.format, to: outputFormat)
                currentConverterInputFormat = sourceBuffer.format
            }
            guard let currentConverter else { throw RealtimeAudioHistoryRecorderError.conversionUnavailable }

            let ratio = outputFormat.sampleRate / sourceBuffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up)) + 1
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw RealtimeAudioHistoryRecorderError.conversionUnavailable
            }

            var didProvideInput = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if didProvideInput {
                    status.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                status.pointee = .haveData
                return sourceBuffer
            }

            var error: NSError?
            let status = currentConverter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            guard status != .error, error == nil, outputBuffer.frameLength > 0 else {
                throw error ?? RealtimeAudioHistoryRecorderError.conversionUnavailable
            }
            return outputBuffer
        }

        private func finalizeCurrentSegmentLocked() {
            guard let currentFileURL,
                  let sampleRate = currentFile?.processingFormat.sampleRate
            else {
                return
            }
            let duration = Double(currentSegmentFrames) / sampleRate
            currentFile = nil
            self.currentFileURL = nil
            currentConverter = nil
            currentConverterInputFormat = nil

            guard duration > 0 else {
                try? fileManager.removeItem(at: currentFileURL)
                return
            }

            let attributes = try? fileManager.attributesOfItem(atPath: currentFileURL.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let relativePath = "\(directoryName)/\(currentFileURL.lastPathComponent)"
            segments.append(RealtimeHistoryAudioSegment(
                relativePath: relativePath,
                offset: currentSegmentOffset,
                duration: duration,
                byteCount: byteCount
            ))
            currentSegmentFrames = 0
        }

        private func snapshotLocked() -> RealtimeHistoryAudioRecording? {
            guard !directoryName.isEmpty, !segments.isEmpty else { return nil }
            return RealtimeHistoryAudioRecording(
                id: recordingID,
                source: recordingSource,
                directoryName: directoryName,
                sampleRate: 16000,
                channelCount: 1,
                segments: segments
            )
        }

        private func completedDurationLocked() -> TimeInterval {
            segments.reduce(0) { $0 + $1.duration }
        }

        private func resetLocked() {
            currentFile = nil
            currentFileURL = nil
            currentConverter = nil
            currentConverterInputFormat = nil
            directoryURL = nil
            directoryName = ""
            recordingSource = .microphone
            segments.removeAll()
            currentSegmentIndex = 0
            currentSegmentOffset = 0
            currentSegmentFrames = 0
            isActive = false
            isPaused = false
        }
    }

    private enum RealtimeAudioHistoryRecorderError: Error {
        case conversionUnavailable
    }
#endif
