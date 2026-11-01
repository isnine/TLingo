#if os(iOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    /// Hands iPhone Audio from the broadcast upload extension to the host app, which runs local
    /// recognition models that do not fit in the extension's memory limit.
    ///
    /// The extension writes 16 kHz mono Float32 samples into numbered segment files under the
    /// App Group container. A segment is closed before the next one is created, so once segment
    /// `n + 1` exists the reader may consume `n` to its end and delete it.
    public enum RealtimeAudioRelay {
        public static let sampleRate: Double = 16000
        static let segmentSampleCount = Int(sampleRate) * 5
        /// Segments the host has not consumed after this many are dropped so a dead host cannot fill the disk.
        static let retainedSegmentCount = 12
        private static let directoryName = "RealtimeAudioRelay"

        static func rootDirectory() -> URL? {
            FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: AppPreferences.appGroupSuiteName)?
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        static func directory(sessionID: String) -> URL? {
            rootDirectory()?.appendingPathComponent(sessionID, isDirectory: true)
        }

        static func segmentURL(index: Int, in directory: URL) -> URL {
            directory.appendingPathComponent(String(format: "%08d.pcm", index), isDirectory: false)
        }

        /// Removes relay data left by every session except `keeping`.
        public static func removeStaleSessions(keeping sessionID: String?) {
            guard let root = rootDirectory(),
                  let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path)
            else { return }
            for entry in entries where entry != sessionID {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(entry, isDirectory: true))
                log("removed stale session=\(entry)")
            }
        }

        static func log(_ message: String) {
            RealtimeLog.log("relay", message)
        }

        static func warn(_ message: String) {
            RealtimeLog.warn("relay", message)
        }
    }

    /// Extension side: converts ReplayKit app audio and appends it to the relay. Called on ReplayKit's sample queue.
    public final class RealtimeAudioRelayWriter: @unchecked Sendable {
        private static let statsInterval: TimeInterval = 5

        private let directory: URL
        private let converter: RealtimePCMBufferConverter
        private let lock = NSLock()
        private var handle: FileHandle?
        private var segmentIndex = 0
        private var segmentSampleCount = 0
        private var totalSampleCount = 0
        private var droppedBufferCount = 0
        private var lastStatsAt = Date()
        private var isClosed = false

        public init?(sessionID: String) {
            guard let directory = RealtimeAudioRelay.directory(sessionID: sessionID),
                  let converter = RealtimePCMBufferConverter(
                      sampleRate: RealtimeAudioRelay.sampleRate,
                      commonFormat: .pcmFormatFloat32
                  )
            else {
                RealtimeAudioRelay.warn("writer init failed session=\(sessionID) reason=noContainerOrConverter")
                return nil
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                RealtimeAudioRelay.warn("writer init failed session=\(sessionID) error=\(error)")
                return nil
            }
            self.directory = directory
            self.converter = converter
            RealtimeAudioRelay.log("writer opened session=\(sessionID)")
        }

        /// Returns the input level of the appended audio for the shared state heartbeat.
        @discardableResult
        public func append(_ sampleBuffer: CMSampleBuffer) -> Float? {
            let level = realtimeAudioLevel(from: sampleBuffer)
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return level }
            guard let pcmBuffer = converter.pcmBuffer(from: sampleBuffer),
                  let channel = pcmBuffer.floatChannelData?[0]
            else {
                droppedBufferCount += 1
                return level
            }
            let frameCount = Int(pcmBuffer.frameLength)
            var offset = 0
            while offset < frameCount {
                guard let handle = currentHandle() else {
                    droppedBufferCount += 1
                    return level
                }
                let count = min(frameCount - offset, RealtimeAudioRelay.segmentSampleCount - segmentSampleCount)
                handle.write(Data(bytes: channel + offset, count: count * MemoryLayout<Float>.size))
                offset += count
                segmentSampleCount += count
                totalSampleCount += count
                if segmentSampleCount >= RealtimeAudioRelay.segmentSampleCount {
                    rollSegment()
                }
            }
            logStatsIfNeeded()
            return level
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            isClosed = true
            try? handle?.close()
            handle = nil
            RealtimeAudioRelay.log(
                "writer closed segment=\(segmentIndex) totalSeconds=\(seconds(totalSampleCount)) dropped=\(droppedBufferCount)"
            )
        }

        private func currentHandle() -> FileHandle? {
            if let handle { return handle }
            let url = RealtimeAudioRelay.segmentURL(index: segmentIndex, in: directory)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                // The host keeps reading after the device locks.
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            ), let handle = try? FileHandle(forWritingTo: url) else {
                RealtimeAudioRelay.warn("segment create failed index=\(segmentIndex)")
                return nil
            }
            self.handle = handle
            return handle
        }

        private func rollSegment() {
            try? handle?.close()
            handle = nil
            segmentSampleCount = 0
            segmentIndex += 1
            let expired = segmentIndex - RealtimeAudioRelay.retainedSegmentCount
            if expired >= 0 {
                let url = RealtimeAudioRelay.segmentURL(index: expired, in: directory)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    RealtimeAudioRelay.warn("segment expired unread index=\(expired)")
                }
            }
        }

        private func logStatsIfNeeded() {
            let now = Date()
            guard now.timeIntervalSince(lastStatsAt) >= Self.statsInterval else { return }
            lastStatsAt = now
            RealtimeAudioRelay.log(
                "writer stats segment=\(segmentIndex) totalSeconds=\(seconds(totalSampleCount)) dropped=\(droppedBufferCount)"
            )
        }
    }

    /// Host side: reads relayed samples in order and deletes consumed segments. Use from one task only.
    final class RealtimeAudioRelayReader: @unchecked Sendable {
        private static let statsInterval: TimeInterval = 5

        private let directory: URL
        private var segmentIndex = 0
        private var segmentOffset: UInt64 = 0
        private(set) var totalSampleCount = 0
        private var lastStatsAt = Date()

        init?(sessionID: String) {
            guard let directory = RealtimeAudioRelay.directory(sessionID: sessionID) else {
                RealtimeAudioRelay.warn("reader init failed session=\(sessionID) reason=noContainer")
                return nil
            }
            self.directory = directory
            RealtimeAudioRelay.log("reader opened session=\(sessionID)")
        }

        /// Returns every sample written since the previous call, or nil when nothing is new.
        func readAvailable() -> AVAudioPCMBuffer? {
            var samples = Data()
            while true {
                let url = RealtimeAudioRelay.segmentURL(index: segmentIndex, in: directory)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    // The writer expired it, or has not started; jump to the oldest segment still present.
                    if let next = oldestSegmentIndex(), next > segmentIndex {
                        RealtimeAudioRelay.warn("reader skipped segments from=\(segmentIndex) to=\(next)")
                        segmentIndex = next
                        segmentOffset = 0
                        continue
                    }
                    break
                }
                // Check for the next segment first: if it exists, this one is complete.
                let nextURL = RealtimeAudioRelay.segmentURL(index: segmentIndex + 1, in: directory)
                let isComplete = FileManager.default.fileExists(atPath: nextURL.path)
                samples.append(readRemainder(of: url))
                guard isComplete else { break }
                try? FileManager.default.removeItem(at: url)
                segmentIndex += 1
                segmentOffset = 0
            }
            guard !samples.isEmpty else { return nil }
            let frameCount = samples.count / MemoryLayout<Float>.size
            totalSampleCount += frameCount
            logStatsIfNeeded()
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: RealtimeAudioRelay.sampleRate,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
            let channel = buffer.floatChannelData?[0]
            else { return nil }
            samples.withUnsafeBytes { raw in
                _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: frameCount * MemoryLayout<Float>.size))
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            return buffer
        }

        func removeAll() {
            try? FileManager.default.removeItem(at: directory)
            RealtimeAudioRelay.log("reader removed relay totalSeconds=\(seconds(totalSampleCount))")
        }

        private func readRemainder(of url: URL) -> Data {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: segmentOffset)
                var data = try handle.readToEnd() ?? Data()
                // A sample may be half written; leave its bytes for the next read.
                let usable = data.count - data.count % MemoryLayout<Float>.size
                data = data.prefix(usable)
                segmentOffset += UInt64(usable)
                return data
            } catch {
                RealtimeAudioRelay.warn("segment read failed index=\(segmentIndex) error=\(error)")
                return Data()
            }
        }

        private func oldestSegmentIndex() -> Int? {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
            return entries.compactMap { Int($0.replacingOccurrences(of: ".pcm", with: "")) }.min()
        }

        private func logStatsIfNeeded() {
            let now = Date()
            guard now.timeIntervalSince(lastStatsAt) >= Self.statsInterval else { return }
            lastStatsAt = now
            RealtimeAudioRelay.log("reader stats segment=\(segmentIndex) totalSeconds=\(seconds(totalSampleCount))")
        }
    }

    private func seconds(_ sampleCount: Int) -> String {
        String(format: "%.1f", Double(sampleCount) / RealtimeAudioRelay.sampleRate)
    }
#endif
