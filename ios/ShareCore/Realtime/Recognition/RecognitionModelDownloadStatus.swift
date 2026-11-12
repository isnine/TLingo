#if os(macOS) || os(iOS)
    import Foundation

    public struct RecognitionModelDownloadStatus: Equatable, Sendable {
        public enum Phase: Sendable {
            case preparing, downloading, installing, completed, failed, cancelled
        }

        public var phase: Phase = .preparing
        public var fractionCompleted = 0.0
        public var downloadedBytes: Int64 = 0
        public var totalBytes: Int64?
        public var bytesPerSecond: Double?
        public var remainingSeconds: Double?
        public var errorMessage: String?
        public var requiresForeground = false

        public var isActive: Bool {
            switch phase {
            case .preparing, .downloading, .installing: true
            case .completed, .failed, .cancelled: false
            }
        }

        public var phaseDescription: String {
            switch phase {
            case .preparing: String(localized: "Preparing download…")
            case .downloading: String(localized: "Downloading model")
            case .installing: String(localized: "Preparing model…")
            case .completed: String(localized: "Download complete")
            case .failed: String(localized: "Download failed")
            case .cancelled: String(localized: "Download cancelled")
            }
        }

        public var transferDescription: String {
            var parts: [String] = []
            if downloadedBytes > 0 || totalBytes != nil {
                let downloaded = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
                if let totalBytes {
                    let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                    parts.append("\(downloaded) / \(total)")
                } else {
                    parts.append(downloaded)
                }
            }
            if let speedDescription {
                parts.append(speedDescription)
            }
            return parts.joined(separator: " · ")
        }

        private var speedDescription: String? {
            guard phase == .downloading, let bytesPerSecond else { return nil }
            let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
            return String(localized: "\(speed)/s")
        }

        public var remainingDescription: String? {
            guard phase == .downloading, let remainingSeconds,
                  remainingSeconds.isFinite, remainingSeconds > 0
            else { return nil }
            let duration = Duration.seconds(min(remainingSeconds, 86400))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
            return String(localized: "About \(duration) remaining")
        }

        public var activityDescription: String {
            guard phase == .downloading else { return phaseDescription }
            let percent = fractionCompleted.formatted(.percent.precision(.fractionLength(0)))
            return [percent, speedDescription, remainingDescription]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }

        static func failureMessage(for error: Error) -> String {
            if case RecognitionModelStoreError.checksumMismatch = error {
                return String(localized: "Model verification failed. Tap Retry to download it again.")
            }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .networkConnectionLost:
                    return String(localized: "Connection lost. Check your network, then tap Retry.")
                case .timedOut:
                    return String(localized: "Download timed out. Check your network, then tap Retry.")
                default: break
                }
            }
            return String(localized: "Download failed. Check your connection and available storage, then tap Retry.")
        }
    }

    struct RecognitionModelDownloadMetrics {
        private var samples: [(time: TimeInterval, bytes: Int64, fraction: Double)] = []

        mutating func sample(
            _ status: inout RecognitionModelDownloadStatus,
            bytes: Int64,
            at time: TimeInterval
        ) {
            status.downloadedBytes = max(0, bytes)
            let current = (time: time, bytes: bytes, fraction: status.fractionCompleted)
            if status.phase != .downloading || samples.last.map({ bytes < $0.bytes || time <= $0.time }) == true {
                samples = [current]
                status.bytesPerSecond = nil
                status.remainingSeconds = nil
                return
            }
            samples.append(current)
            while samples.count > 2, samples[1].time < time - 5 {
                samples.removeFirst()
            }
            guard let baseline = samples.first, time > baseline.time else { return }
            let elapsed = time - baseline.time
            let speed = Double(bytes - baseline.bytes) / elapsed
            status.bytesPerSecond = speed
            let fractionDelta = status.fractionCompleted - baseline.fraction
            if speed > 0, elapsed >= 3, let total = status.totalBytes {
                status.remainingSeconds = Double(max(0, total - bytes)) / speed
            } else if speed > 0, elapsed >= 3, fractionDelta > 0 {
                status.remainingSeconds = (1 - status.fractionCompleted) * elapsed / fractionDelta
            } else {
                status.remainingSeconds = nil
            }
        }
    }
#endif
