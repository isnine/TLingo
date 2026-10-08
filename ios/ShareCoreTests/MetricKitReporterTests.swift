//
//  MetricKitReporterTests.swift
//  ShareCoreTests
//

import Foundation
@testable import ShareCore
import Testing

@Suite("MetricKitReporter")
struct MetricKitReporterTests {
    private func makeReporter() -> (MetricKitReporter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricKitReporterTests-\(UUID().uuidString)", isDirectory: true)
        return (MetricKitReporter(directory: directory), directory)
    }

    @Test func prunesToNewestStoredPayloads() {
        let (reporter, directory) = makeReporter()
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0 ..< 25 {
            reporter.store(Data(#"{"index":\#(index)}"#.utf8), kind: .metrics)
        }

        #expect(reporter.storedFiles().count == 20)
    }

    @Test func logsNewestPayloadsAsCompactJSONLines() {
        let (reporter, directory) = makeReporter()
        defer { try? FileManager.default.removeItem(at: directory) }

        reporter.store(Data(#"{"timeStampBegin": "old"}"#.utf8), kind: .metrics)
        Thread.sleep(forTimeInterval: 0.005)
        reporter.store(Data(#"{"crashDiagnostics": [{"diagnosticMetaData": {"signal": 11}}]}"#.utf8), kind: .diagnostics)

        let lines = reporter.logLines()

        #expect(lines == [
            #"[MetricKit] diagnostics {"crashDiagnostics":[{"diagnosticMetaData":{"signal":11}}]}"#,
            #"[MetricKit] metrics {"timeStampBegin":"old"}"#,
        ])
    }
}
