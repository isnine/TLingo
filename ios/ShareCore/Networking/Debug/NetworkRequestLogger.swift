import Combine
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "NetworkRequestLogger")

@MainActor
public final class NetworkRequestLogger: ObservableObject {
    public static let shared = NetworkRequestLogger()
    @Published public private(set) var records: [NetworkRequestRecord] = []

    private static let maxRecords = 500
    private let directory: URL?

    private convenience init() {
        self.init(directory: Self.defaultDirectory)
    }

    init(directory: URL?) {
        self.directory = directory
    }

    private static var defaultDirectory: URL? {
        #if os(iOS)
            if let group = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppPreferences.appGroupSuiteName
            ) {
                return group.appendingPathComponent("Library/Caches/NetworkDebug", isDirectory: true)
            }
        #endif
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NetworkDebug", isDirectory: true)
    }

    public nonisolated static func addRecord(_ record: NetworkRequestRecord) {
        Task { @MainActor in shared.store(record) }
    }

    func store(_ record: NetworkRequestRecord) {
        let sanitized = record.sanitizedForDebug()
        records.removeAll { $0.id == sanitized.id }
        records.append(sanitized)
        records.sort { $0.timestamp > $1.timestamp }
        records = Array(records.prefix(Self.maxRecords))
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            // Independent atomic files prevent the app and extension from overwriting each other.
            let name = String(format: "%020.3f", sanitized.timestamp.timeIntervalSince1970) + "-\(sanitized.id).json"
            try encoder.encode(sanitized).write(to: directory.appendingPathComponent(name), options: .atomic)
            for file in try recordFiles().dropFirst(Self.maxRecords) {
                try? FileManager.default.removeItem(at: file)
            }
            // The readable log is regenerated on export; rebuilding it here re-decoded every record per request.
        } catch {
            logger.error("Failed to write network record: \(error, privacy: .public)")
        }
    }

    public func reloadFromFile() {
        guard directory != nil else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            records = try recordFiles().prefix(Self.maxRecords).compactMap { file in
                guard let data = try? Data(contentsOf: file),
                      let record = try? decoder.decode(NetworkRequestRecord.self, from: data) else { return nil }
                return record.sanitizedForDebug()
            }.sorted { $0.timestamp > $1.timestamp }
        } catch {
            logger.error("Failed to read network records: \(error, privacy: .public)")
        }
    }

    /// Regenerate the readable log from persisted records, including extension requests.
    @discardableResult
    public func writeLocalLog() throws -> URL {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reloadFromFile()
        let fileURL = directory.appendingPathComponent("tlingo-local.log")
        let log = FeedbackLogFormatter.makeLog(records: records, metricKitLines: MetricKitReporter.shared.logLines())
        try log.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    public func clearAll() {
        records.removeAll()
        for file in (try? recordFiles()) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        do {
            try writeLocalLog()
        } catch {
            logger.error("Failed to clear local log: \(error, privacy: .public)")
        }
    }

    private func recordFiles() throws -> [URL] {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
