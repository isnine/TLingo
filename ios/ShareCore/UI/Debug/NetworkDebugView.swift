//
//  NetworkDebugView.swift
//  ShareCore
//
//  Created by Copilot on 2026/02/28.
//

import SwiftUI

/// Debug view showing all network request history.
public struct NetworkDebugView: View {
    @ObservedObject private var logger = NetworkRequestLogger.shared
    @State private var searchText = ""
    @State private var selectedSource: NetworkRequestRecord.Source?
    @State private var failuresOnly = false
    @State private var selectedRecord: NetworkRequestRecord?

    public init() {}

    private var filteredRecords: [NetworkRequestRecord] {
        var result = logger.records.sorted { $0.timestamp > $1.timestamp }
        if failuresOnly {
            result = result.filter { $0.errorDescription != nil || !((200 ... 299).contains($0.statusCode ?? 0)) }
        }
        if let source = selectedSource {
            result = result.filter { $0.source == source }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.url.lowercased().contains(query)
                    || $0.httpMethod.lowercased().contains(query)
                    || ($0.statusCode.map(String.init)?.contains(query) ?? false)
                    || ($0.errorDescription?.lowercased().contains(query) ?? false)
            }
        }
        return result
    }

    public var body: some View {
        Group {
            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    "No Requests",
                    systemImage: "network.slash",
                    description: Text("Network requests will appear here as they are made.")
                )
            } else {
                List {
                    ForEach(filteredRecords) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            RequestRowView(record: record)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Network Log")
        .searchable(text: $searchText, prompt: "Filter by URL or method")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    NavigationLink {
                        LocalLogView()
                    } label: {
                        Label("Local Log", systemImage: "doc.text")
                    }

                    Toggle("Errors Only", isOn: $failuresOnly)

                    Button("Copy Latest 10 Reports", systemImage: "doc.on.doc") {
                        PasteboardHelper.copy(filteredRecords.prefix(10).map(\.debugReport).joined(separator: "\n\n---\n\n"))
                    }
                    .disabled(filteredRecords.isEmpty)

                    Divider()
                    Button(role: .destructive) {
                        withAnimation {
                            logger.clearAll()
                        }
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }

                    Button {
                        logger.reloadFromFile()
                    } label: {
                        Label("Reload from Extension", systemImage: "arrow.clockwise")
                    }

                    Divider()

                    Picker("Source", selection: $selectedSource) {
                        Text("All Sources").tag(nil as NetworkRequestRecord.Source?)
                        Text("App").tag(NetworkRequestRecord.Source.app as NetworkRequestRecord.Source?)
                        Text("Extension").tag(NetworkRequestRecord.Source.extension as NetworkRequestRecord.Source?)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            logger.reloadFromFile()
        }
        .onAppear {
            logger.reloadFromFile()
        }
        .sheet(item: $selectedRecord) { record in
            NavigationStack {
                NetworkRequestDetailView(record: record)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedRecord = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            #if os(macOS)
                .frame(minWidth: 600, minHeight: 500)
            #endif
        }
    }
}

// MARK: - Row View

private struct RequestRowView: View {
    let record: NetworkRequestRecord

    var body: some View {
        HStack(spacing: 12) {
            // Method badge
            Text(record.httpMethod)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(methodColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.urlPath)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let code = record.statusCode {
                        Text("\(code)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(statusColor)
                    }
                    if record.statusCode == nil {
                        Text("No response").foregroundStyle(.red)
                    }
                    Text(record.formattedLatency)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if record.source == .extension {
                        Text("EXT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }

                    if record.errorDescription != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            Text(record.timestamp, style: .time)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var methodColor: Color {
        switch record.httpMethod {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "DELETE": return .red
        default: return .gray
        }
    }

    private var statusColor: Color {
        switch record.statusColor {
        case .success: return .green
        case .clientError: return .orange
        case .serverError: return .red
        case .unknown: return .secondary
        }
    }
}
