//
//  FeedbackLogSanitizerTests.swift
//  ShareCoreTests
//

import Foundation
@testable import ShareCore
import Testing

@Suite("FeedbackLogSanitizer")
struct FeedbackLogSanitizerTests {
    @Test func formatsPlainTextLogWithTimestampPerLine() {
        let timestamp = Date(timeIntervalSince1970: 0)
        let record = NetworkRequestRecord(
            timestamp: timestamp,
            source: .app,
            httpMethod: "POST",
            url: "https://example.com/chat/completions?code=<redacted>",
            requestHeaders: [
                "Content-Type": "application/json",
                "X-Signature": "<redacted>",
            ],
            requestBodyByteCount: 128,
            statusCode: 200,
            responseBodyByteCount: 256,
            latency: 0.42
        )

        let log = FeedbackLogFormatter.makeLog(records: [record], generatedAt: timestamp)
        let lines = log.split(separator: "\n", omittingEmptySubsequences: true)

        #expect(lines.allSatisfy { $0.hasPrefix("1970-01-01T00:00:00.000Z ") })
        #expect(log.contains("[Network] source=app method=POST status=200 latency=420ms"))
        #expect(log.contains("request_bytes=128 response_bytes=256"))
        #expect(log.contains("request.headers: Content-Type=application/json; X-Signature=<redacted>"))
        #expect(!log.contains("secret-signature"))
        #expect(!log.contains("request.body"))
        #expect(!log.contains("response.body"))
    }

    @Test func redactsSensitiveHeaders() {
        let sanitized = FeedbackLogSanitizer.sanitizeHeaders([
            "Content-Type": "application/json",
            "X-Signature": "secret-signature",
            "Authorization": "Bearer token",
            "X-Onboarding-Trial": "trial-signature",
        ])

        #expect(sanitized["Content-Type"] == "application/json")
        #expect(sanitized["X-Signature"] == "<redacted>")
        #expect(sanitized["Authorization"] == "<redacted>")
        #expect(sanitized["X-Onboarding-Trial"] == "<redacted>")
    }

    @Test func redactsSensitiveJSONFields() throws {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "message": "hello",
                "access_token": "access",
                "nested": [
                    "refresh_token": "refresh",
                    "value": "kept",
                ],
            ]
        )

        let sanitized = try #require(FeedbackLogSanitizer.sanitizeBody(body))

        #expect(sanitized.contains("\"message\" : \"hello\""))
        #expect(sanitized.contains("\"access_token\" : \"<redacted>\""))
        #expect(sanitized.contains("\"refresh_token\" : \"<redacted>\""))
        #expect(!sanitized.contains("\"access\""))
        #expect(!sanitized.contains("\"refresh\""))
    }

    @Test func redactsURLQueryValues() {
        let sanitized = FeedbackLogSanitizer.sanitizeURL(
            URL(string: "https://example.com/oauth/callback?code=secret-code&state=secret-state")
        )

        #expect(sanitized == "https://example.com/oauth/callback?code=%3Credacted%3E&state=%3Credacted%3E")
        #expect(!sanitized.contains("secret-code"))
        #expect(!sanitized.contains("secret-state"))
    }

    @Test func redactsFreeformLogSecrets() {
        let sanitized = FeedbackLogSanitizer.sanitizeLogMessage(
            "url=https://example.com/callback?code=secret-code token=secret-token Authorization=Bearer abc.def"
        )

        #expect(sanitized.contains("code=<redacted>"))
        #expect(sanitized.contains("token=<redacted>"))
        #expect(sanitized.contains("Authorization=<redacted>"))
        #expect(!sanitized.contains("secret-code"))
        #expect(!sanitized.contains("secret-token"))
        #expect(!sanitized.contains("abc.def"))
    }

    @Test @MainActor func retainsAllOutcomesAcrossLoggerInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = NetworkRequestLogger(directory: directory)
        let ext = NetworkRequestLogger(directory: directory)
        let statuses: [Int?] = [200, 201, 204, 400, 500, nil]
        for (index, status) in statuses.enumerated() {
            let record = NetworkRequestRecord(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                source: index.isMultiple(of: 2) ? .app : .extension,
                httpMethod: "POST", url: "https://example.com/chat/completions",
                requestHeaders: ["Authorization": "Bearer private-token"],
                requestBody: Data(#"{"messages":[{"role":"user","content":"Translate to Japanese"}],"token":"secret-value"}"#
                    .utf8),
                statusCode: status, responseBody: Data(#"{"text":"こんにちは"}"#.utf8),
                errorDescription: status == nil ? "NSURLErrorDomain (-1009): offline" : nil
            )
            (index.isMultiple(of: 2) ? app : ext).store(record)
        }
        app.reloadFromFile()
        #expect(app.records.count == 6)
        #expect(app.records.first?.statusCode == nil)
        #expect(app.records.contains { $0.statusCode == 200 })
        let report = try #require(app.records.first).debugReport
        #expect(report.contains("Translate to Japanese"))
        #expect(report.contains("こんにちは"))
        #expect(report.contains("Network error"))
        #expect(!report.contains("private-token"))
        #expect(!report.contains("secret-value"))
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let persisted = try String(contentsOf: file, encoding: .utf8)
            #expect(!persisted.contains("private-token"))
            #expect(!persisted.contains("secret-value"))
        }
        app.clearAll()
        ext.reloadFromFile()
        #expect(ext.records.isEmpty)
    }

    @Test func streamingReportRedactsCredentialsAndPreservesEvents() {
        let response = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}],\"token\":\"hidden\"}\n\ndata: [DONE]\n"
        let record = NetworkRequestRecord(
            source: .extension, httpMethod: "POST", url: "https://example.com/model/chat/completions?key=hidden",
            requestHeaders: [:], statusCode: 200, responseBody: Data(response.utf8)
        ).sanitizedForDebug().sanitizedForDebug()
        let report = record.debugReport
        #expect(report.contains("你好"))
        #expect(report.contains("[DONE]"))
        #expect(!report.contains("hidden"))
        #expect(report.contains("HTTP success"))
        #expect(report.contains("Model output:\n你好"))
    }

    @Test @MainActor func capturesRealTransportFailure() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:1/debug-transport-test/\(UUID())"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DebugNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"text":"Debug probe","token":"private-test-value"}"#.utf8)
        DebugNetworkProtocol.preserveBodyForDebug(in: &request)
        do {
            _ = try await session.data(for: request)
            Issue.record("Expected a connection failure on the closed loopback port")
        } catch {}
        for _ in 0 ..< 20 {
            if NetworkRequestLogger.shared.records.contains(where: { $0.url == url.absoluteString }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let record = try #require(NetworkRequestLogger.shared.records.first { $0.url == url.absoluteString })
        #expect(record.statusCode == nil)
        #expect(record.errorDescription != nil)
        #expect(record.debugReport.contains("Debug probe"))
        #expect(!record.debugReport.contains("private-test-value"))
    }

    @Test @MainActor func retentionKeepsNewestRecordsAfterReloadAndNewWrites() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = NetworkRequestLogger(directory: directory)
        for index in 0 ... 500 {
            logger.store(NetworkRequestRecord(
                timestamp: Date(timeIntervalSince1970: Double(index) / 1000),
                source: .app,
                httpMethod: "GET",
                url: "https://example.com/\(index)",
                requestHeaders: [:],
                statusCode: 200
            ))
        }
        logger.reloadFromFile()
        #expect(logger.records.count == 500)
        #expect(logger.records.first?.urlPath == "/500")
        #expect(logger.records.last?.urlPath == "/1")
    }

    @Test func oversizedAndIncompleteBodiesAreExplicitlyOmitted() {
        for body in [Data(repeating: 65, count: NetworkRequestRecord.bodyCaptureLimit + 1), Data(#"{"token":"unfinished"#.utf8)] {
            let record = NetworkRequestRecord(
                source: .app,
                httpMethod: "POST",
                url: "https://example.com",
                requestHeaders: [:],
                requestBody: body
            )
            let report = record.debugReport
            #expect(!report.contains("unfinished"))
            #expect(report.contains("omitted") || report.contains("exceeded capture limit"))
        }
    }

    @Test @MainActor func localFileAndFeedbackAttachmentSharePersistedRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = NetworkRequestLogger(directory: directory)
        writer.store(NetworkRequestRecord(
            source: .extension,
            httpMethod: "GET",
            url: "https://example.com/success",
            requestHeaders: ["Authorization": "Bearer private-token"],
            statusCode: 200
        ))
        let localFile = directory.appendingPathComponent("tlingo-local.log")
        let initial = try String(contentsOf: localFile, encoding: .utf8)
        #expect(initial.contains("status=200"))
        writer.store(NetworkRequestRecord(
            source: .app,
            httpMethod: "POST",
            url: "https://example.com/failure",
            requestHeaders: [:],
            errorDescription: "Connection failed"
        ))
        let reader = NetworkRequestLogger(directory: directory)
        let attachment = try #require(FeedbackLogExporter.makeAttachmentFile(logger: reader))
        defer { try? FileManager.default.removeItem(at: attachment) }
        let persisted = try String(contentsOf: localFile, encoding: .utf8)
        let attached = try String(contentsOf: attachment, encoding: .utf8)
        #expect(persisted == attached)
        #expect(persisted.contains("source=extension method=GET status=200"))
        #expect(persisted.contains("Connection failed"))
        #expect(!persisted.contains("private-token"))
        writer.clearAll()
        #expect(try String(contentsOf: localFile, encoding: .utf8).contains("record_count=0"))
        #expect(try String(contentsOf: attachment, encoding: .utf8) == attached)
    }
}
