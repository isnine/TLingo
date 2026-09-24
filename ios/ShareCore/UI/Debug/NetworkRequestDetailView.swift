//
//  NetworkRequestDetailView.swift
//  ShareCore
//
//  Created by Copilot on 2026/02/28.
//

import SwiftUI

/// Detail view for a single network request record.
public struct NetworkRequestDetailView: View {
    let record: NetworkRequestRecord

    @State private var copiedReport = false

    public init(record: NetworkRequestRecord) {
        self.record = record.sanitizedForDebug()
    }

    public var body: some View {
        List {
            Section {
                Button {
                    PasteboardHelper.copy(record.debugReport)
                    copiedReport = true
                } label: {
                    Label(copiedReport ? "Copied" : "Copy Debug Report", systemImage: copiedReport ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("network_debug_copy_report")
            } footer: {
                Text("Includes captured request and response text. Credentials are redacted. Review your text before sharing.")
            }

            // MARK: - Overview

            Section("Overview") {
                LabeledRow(label: "Result", value: record.outcome)
                LabeledRow(label: "Request ID", value: record.id.uuidString, monospaced: true)
                LabeledRow(label: "Method", value: record.httpMethod)
                LabeledRow(label: "URL", value: record.url, monospaced: true)
                if let code = record.statusCode {
                    LabeledRow(label: "Status", value: "\(code)")
                }
                LabeledRow(label: "Latency", value: record.formattedLatency)
                LabeledRow(label: "Timestamp", value: formatted(record.timestamp))
                LabeledRow(label: "Source", value: record.source == .app ? "App" : "Extension")
                if let error = record.errorDescription {
                    LabeledRow(label: "Error", value: error)
                }
            }

            // MARK: - Request Headers

            Section("Request Headers") {
                if record.requestHeaders.isEmpty {
                    Text("No headers")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(record.requestHeaders.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            Text(value)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // MARK: - Request Body

            Section {
                BodyContentView(
                    title: "Request Body",
                    content: record.requestBodyString
                )
            } header: {
                HStack {
                    Text("Request Body")
                    Spacer()
                    if let body = record.requestBodyString {
                        DebugCopyButton(text: body)
                    }
                }
            }

            // MARK: - Response Headers

            if let headers = record.responseHeaders {
                Section("Response Headers") {
                    ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            Text(value)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            // MARK: - Response Body

            Section {
                BodyContentView(
                    title: "Response Body",
                    content: record.responseBodyString
                )
            } header: {
                HStack {
                    Text("Response Body")
                    Spacer()
                    if let body = record.responseBodyString {
                        DebugCopyButton(text: body)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Request Detail")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}

// MARK: - Subviews

private struct LabeledRow: View {
    let label: LocalizedStringKey
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Group {
                if monospaced {
                    Text(value)
                        .font(.system(size: 13, design: .monospaced))
                } else {
                    Text(value)
                        .font(.system(size: 14))
                }
            }
            .textSelection(.enabled)
        }
    }
}

private struct BodyContentView: View {
    let title: String
    let content: String?

    @State private var isExpanded = false

    var body: some View {
        if let bodyText = content {
            VStack(alignment: .leading, spacing: 8) {
                let displayText = isExpanded ? bodyText : String(bodyText.prefix(2000))
                Text(displayText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)

                if bodyText.count > 2000 {
                    Button(
                        isExpanded ? String(localized: "Show Less") :
                            String(localized: "Show All (\(bodyText.count) chars)")
                    ) {
                        isExpanded.toggle()
                    }
                    .font(.system(size: 12))
                }
            }
        } else {
            Text("Body not captured")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
        }
    }
}

private struct DebugCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            PasteboardHelper.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
    }
}
