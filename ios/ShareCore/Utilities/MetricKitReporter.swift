import Foundation
import MetricKit
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "MetricKit")

/// Keeps recent MetricKit payloads on disk so feedback and diagnostic logs carry field crashes, hangs and launch metrics.
public final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = MetricKitReporter()

    private static let maxStoredPayloads = 20
    private static let maxLoggedPayloads = 5
    private static let payloadCharacterLimit = 40000

    private let directory: URL?
    private let lock = NSLock()
    private var isStarted = false

    init(directory: URL? = MetricKitReporter.defaultDirectory) {
        self.directory = directory
    }

    public func start() {
        let shouldStart = lock.withLock {
            defer { isStarted = true }
            return !isStarted
        }
        guard shouldStart else { return }
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: .metrics)
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            store(payload.jsonRepresentation(), kind: .diagnostics)
        }
    }

    /// Newest payloads first, one compact JSON payload per line.
    public func logLines() -> [String] {
        storedFiles()
            .prefix(Self.maxLoggedPayloads)
            .compactMap { file -> String? in
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      var text = String(data: compact, encoding: .utf8)
                else { return nil }
                if text.count > Self.payloadCharacterLimit {
                    text = String(text.prefix(Self.payloadCharacterLimit)) + "<truncated>"
                }
                let kind = file.lastPathComponent.components(separatedBy: "-").first ?? "payload"
                return "[MetricKit] \(kind) \(text)"
            }
    }

    enum PayloadKind: String {
        case metrics
        case diagnostics
    }

    func store(_ data: Data, kind: PayloadKind) {
        guard let directory else { return }
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stamp = Int(Date().timeIntervalSince1970 * 1000)
                // Zero-padded stamp keeps lexical order chronological within each kind.
                let name = "\(kind.rawValue)-\(String(format: "%015d", stamp))-\(UUID().uuidString).json"
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                for file in storedFiles().dropFirst(Self.maxStoredPayloads) {
                    try? FileManager.default.removeItem(at: file)
                }
            } catch {
                logger.error("Failed to store \(kind.rawValue, privacy: .public) payload: \(error, privacy: .public)")
            }
        }
    }

    /// Newest first across both kinds.
    func storedFiles() -> [URL] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { Self.stamp(of: $0) > Self.stamp(of: $1) }
    }

    private static func stamp(of file: URL) -> String {
        let parts = file.lastPathComponent.components(separatedBy: "-")
        return parts.count > 1 ? parts[1] : ""
    }

    private static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MetricKit", isDirectory: true)
    }
}
