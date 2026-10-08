//
//  FeedbackMail.swift
//  ShareCore
//

import Foundation
import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

#if os(macOS)
    import OSLog
#endif

#if os(iOS) && canImport(MessageUI)
    import MessageUI
#endif

#if canImport(UIKit)
    import UIKit
#endif

public struct FeedbackMailDraft: Identifiable {
    public let id = UUID()
    public let recipient: String
    public let subject: String
    public let body: String
    public let attachmentURL: URL?

    public init(
        recipient: String,
        subject: String,
        body: String,
        attachmentURL: URL?
    ) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.attachmentURL = attachmentURL
    }
}

@MainActor
public enum FeedbackMail {
    public static let recipient = "iamzanderwang@outlook.com"

    public static func makeDraft() -> FeedbackMailDraft {
        makeDraft(isPremium: Entitlement.shared.isPro)
    }

    public static func makeDraft(isPremium: Bool) -> FeedbackMailDraft {
        FeedbackMailDraft(
            recipient: recipient,
            subject: isPremium ? "TLingo Feedback [Premium]" : "TLingo Feedback",
            body: body(isPremium: isPremium),
            attachmentURL: FeedbackLogExporter.makeAttachmentFile()
        )
    }

    public static func openFallback(_ draft: FeedbackMailDraft) {
        guard let url = draft.mailtoURL else { return }
        #if canImport(UIKit)
            UIApplication.shared.open(url)
        #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
        #endif
    }

    #if os(macOS)
        @discardableResult
        public static func openMacComposer(_ draft: FeedbackMailDraft) -> Bool {
            guard let service = NSSharingService(named: .composeEmail) else {
                openFallback(draft)
                return false
            }
            service.recipients = [draft.recipient]
            service.subject = draft.subject
            var items: [Any] = [draft.body]
            if let attachmentURL = draft.attachmentURL {
                items.append(attachmentURL)
            }
            service.perform(withItems: items)
            return true
        }
    #endif

    private static func body(isPremium: Bool) -> String {
        let appVersion = OAuthActivationDiagnostics.currentAppVersion
        let buildNumber = OAuthActivationDiagnostics.currentBuildNumber
        return [
            "Please describe what happened:",
            "",
            "---",
            "App: TLingo \(appVersion) (\(buildNumber))",
            "Plan: \(isPremium ? "Premium" : "Free")",
            "System: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Generated At: \(ISO8601DateFormatter().string(from: Date()))",
            "Log: A sanitized diagnostic log is attached when the mail app supports attachments.",
        ].joined(separator: "\n")
    }
}

public extension FeedbackMailDraft {
    var mailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}

@MainActor
enum FeedbackLogExporter {
    static func makeAttachmentFile(logger: NetworkRequestLogger = .shared) -> URL? {
        do {
            let localFile = try logger.writeLocalLog()
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tlingo-feedback-log-\(Self.fileDateStamp())-\(UUID()).log")
            try FileManager.default.copyItem(at: localFile, to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    private static func fileDateStamp() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}

@MainActor
public enum DiagnosticLogExporter {
    public static func writeLog(to fileURL: URL) throws {
        NetworkRequestLogger.shared.reloadFromFile()
        let records = NetworkRequestLogger.shared.records.sorted { $0.timestamp > $1.timestamp }
        let text = FeedbackLogFormatter.makeLog(
            records: records,
            title: "diagnostic log generated",
            unifiedLogLines: unifiedLogLines(),
            metricKitLines: MetricKitReporter.shared.logLines()
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func unifiedLogLines() -> [String] {
        #if os(macOS)
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(date: Date().addingTimeInterval(-24 * 60 * 60))
                let predicate = NSPredicate(format: "subsystem == %@", "com.zanderwang.AITranslator")
                return try store.getEntries(at: position, matching: predicate)
                    .compactMap { $0 as? OSLogEntryLog }
                    .map { entry in
                        [
                            "\(FeedbackLogFormatter.timestamp(entry.date)) [UnifiedLog]",
                            "level=\(entry.level.rawValue)",
                            "category=\(entry.category)",
                            FeedbackLogSanitizer.sanitizeLogMessage(entry.composedMessage),
                        ].joined(separator: " ")
                    }
            } catch {
                return ["\(FeedbackLogFormatter.timestamp(Date())) [UnifiedLog] export_error=\(error.localizedDescription)"]
            }
        #else
            return []
        #endif
    }
}

enum FeedbackLogSanitizer {
    private static let redactedValue = "<redacted>"
    private static let bodyCharacterLimit = 20000

    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-signature",
        "x-onboarding-trial",
    ]

    private static let sensitiveJSONKeys: Set<String> = [
        "access_token",
        "refresh_token",
        "id_token",
        "token",
        "authorization",
        "password",
        "secret",
        "signature",
        "api_key",
        "apikey",
        "otp",
        "client_secret",
    ]

    static func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            let normalizedKey = pair.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            result[pair.key] = isSensitiveName(normalizedKey) ? redactedValue : pair.value
        }
    }

    static func sanitizeURL(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ""
        }
        components.queryItems = components.queryItems?.map { item in
            URLQueryItem(name: item.name, value: item.value == nil ? nil : redactedValue)
        }
        return components.string ?? url.path
    }

    static func sanitizeBody(_ data: Data?) -> String? {
        guard let data else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) {
            let sanitized = sanitizeJSONObject(object)
            if let encoded = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.prettyPrinted, .sortedKeys]
            ), let text = String(data: encoded, encoding: .utf8) {
                return limited(text)
            }
        }
        return limited(String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
    }

    static func sanitizeLogMessage(_ message: String) -> String {
        let urlRedacted = message
            .components(separatedBy: .whitespacesAndNewlines)
            .map { part in
                guard part.contains("://"), let url = URL(string: part) else { return part }
                return sanitizeURL(url)
            }
            .joined(separator: " ")
        return redactingSensitiveAssignments(in: redactingBearerTokens(in: urlRedacted))
    }

    private static func sanitizeJSONObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                let normalizedKey = pair.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if isSensitiveName(normalizedKey) || sensitiveJSONKeys.contains(normalizedKey) {
                    result[pair.key] = redactedValue
                } else {
                    result[pair.key] = sanitizeJSONObject(pair.value)
                }
            }
        }
        if let array = object as? [Any] {
            return array.map(sanitizeJSONObject)
        }
        if let text = object as? String {
            if text.hasPrefix("data:") { return "<inline data omitted>" }
            return redactingSensitiveAssignments(in: redactingBearerTokens(in: text))
        }
        return object
    }

    private static func limited(_ text: String) -> String {
        guard text.count > bodyCharacterLimit else { return text }
        return String(text.prefix(bodyCharacterLimit)) + "\n<truncated>"
    }

    private static func isSensitiveName(_ normalizedName: String) -> Bool {
        sensitiveHeaderNames.contains(normalizedName)
            || normalizedName.contains("authorization")
            || normalizedName.contains("token")
            || normalizedName.contains("secret")
            || normalizedName.contains("signature")
            || normalizedName.contains("password")
            || normalizedName.contains("api-key")
            || normalizedName.contains("api_key")
            || normalizedName.contains("apikey")
            || normalizedName.contains("cookie")
    }

    private static func redactingBearerTokens(in text: String) -> String {
        replace(
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: text,
            template: "Bearer <redacted>"
        )
    }

    private static func redactingSensitiveAssignments(in text: String) -> String {
        let pattern =
            #"(?i)\b(code|state|token|access_token|refresh_token|id_token|secret|signature|password|api[_-]?key|authorization)=([^\s&]+)"#
        return replace(
            pattern: pattern,
            in: text,
            template: "$1=<redacted>"
        )
    }

    private static func replace(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

enum FeedbackLogFormatter {
    static func makeLog(
        records: [NetworkRequestRecord],
        generatedAt: Date = Date(),
        title: String = "feedback log generated",
        unifiedLogLines: [String] = [],
        metricKitLines: [String] = []
    ) -> String {
        var lines: [String] = []
        let generatedTimestamp = timestamp(generatedAt)
        let appVersion = OAuthActivationDiagnostics.currentAppVersion
        let buildNumber = OAuthActivationDiagnostics.currentBuildNumber
        lines.append("\(generatedTimestamp) [TLingo] \(title)")
        lines.append("\(generatedTimestamp) [TLingo] app=\(appVersion) build=\(buildNumber)")
        lines.append("\(generatedTimestamp) [TLingo] system=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append(contentsOf: unifiedLogLines)
        lines.append(contentsOf: metricKitLines.map { "\(generatedTimestamp) \($0)" })
        lines.append("\(generatedTimestamp) [TLingo] record_count=\(records.count)")

        if records.isEmpty {
            lines.append("\(generatedTimestamp) [Network] no records")
            return lines.joined(separator: "\n") + "\n"
        }

        for record in records {
            append(record, to: &lines)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(_ record: NetworkRequestRecord, to lines: inout [String]) {
        let time = timestamp(record.timestamp)
        let status = record.statusCode.map(String.init) ?? "-"
        let latency = record.latency.map { String(format: "%.0fms", $0 * 1000) } ?? "-"
        let summary = [
            "source=\(record.source.rawValue)",
            "method=\(record.httpMethod)",
            "status=\(status)",
            "latency=\(latency)",
            "url=\(record.url)",
            "request_bytes=\(record.requestBodyByteCount.map(String.init) ?? "-")",
            "response_bytes=\(record.responseBodyByteCount.map(String.init) ?? "-")",
        ].joined(separator: " ")
        lines.append("\(time) [Network] \(summary)")

        let requestHeaders = FeedbackLogSanitizer.sanitizeHeaders(record.requestHeaders)
        append(headers: requestHeaders, label: "request.headers", timestamp: time, to: &lines)

        if let responseHeaders = record.responseHeaders {
            append(
                headers: FeedbackLogSanitizer.sanitizeHeaders(responseHeaders),
                label: "response.headers",
                timestamp: time,
                to: &lines
            )
        }

        if let errorDescription = record.errorDescription, !errorDescription.isEmpty {
            lines.append("\(time) [Network] error=\(FeedbackLogSanitizer.sanitizeLogMessage(errorDescription))")
        }
    }

    private static func append(
        headers: [String: String],
        label: String,
        timestamp: String,
        to lines: inout [String]
    ) {
        guard !headers.isEmpty else { return }
        let text = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        lines.append("\(timestamp) [Network] \(label): \(text)")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

#if os(iOS) && canImport(MessageUI)
    public struct FeedbackMailComposerView: UIViewControllerRepresentable {
        public let draft: FeedbackMailDraft
        public let onFinish: () -> Void

        public init(draft: FeedbackMailDraft, onFinish: @escaping () -> Void) {
            self.draft = draft
            self.onFinish = onFinish
        }

        public func makeUIViewController(context: Context) -> UIViewController {
            guard MFMailComposeViewController.canSendMail() else {
                Task { @MainActor in
                    FeedbackMail.openFallback(draft)
                    onFinish()
                }
                return UIViewController()
            }

            let controller = MFMailComposeViewController()
            controller.mailComposeDelegate = context.coordinator
            controller.setToRecipients([draft.recipient])
            controller.setSubject(draft.subject)
            controller.setMessageBody(draft.body, isHTML: false)
            if let attachmentURL = draft.attachmentURL, let data = try? Data(contentsOf: attachmentURL) {
                controller.addAttachmentData(
                    data,
                    mimeType: "text/plain",
                    fileName: attachmentURL.lastPathComponent
                )
            }
            return controller
        }

        public func updateUIViewController(_: UIViewController, context _: Context) {}

        public func makeCoordinator() -> Coordinator {
            Coordinator(onFinish: onFinish)
        }

        public final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
            private let onFinish: () -> Void

            init(onFinish: @escaping () -> Void) {
                self.onFinish = onFinish
            }

            public func mailComposeController(
                _: MFMailComposeViewController,
                didFinishWith _: MFMailComposeResult,
                error _: Error?
            ) {
                onFinish()
            }
        }
    }
#endif
