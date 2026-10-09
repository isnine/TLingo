//
//  VocabularyView.swift
//  ShareCore
//

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Saved terms with search, deletion and plain-text export. Hosts provide the navigation container.
public struct VocabularyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = VocabularyStore.shared
    @State private var searchText = ""
    #if os(iOS)
        @State private var isExporting = false
        @State private var exportedFileURL: URL?
    #endif

    public init() {}

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var filteredEntries: [VocabularyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.term.localizedCaseInsensitiveContains(query) || $0.translation.localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        content
            .navigationTitle("Vocabulary")
            .searchable(text: $searchText, prompt: Text("Search Vocabulary"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    exportButton
                        .disabled(store.entries.isEmpty)
                        .accessibilityIdentifier("vocabulary_export_button")
                }
            }
        #if os(iOS)
            .background {
                ActivitySheetPresenter(fileURL: $exportedFileURL) { isExporting = false }
            }
        #endif
            .onAppear { store.reload() }
    }

    #if os(iOS)
        /// The system share sheet takes seconds to appear, so the button spins until it is on screen.
        @ViewBuilder
        private var exportButton: some View {
            if isExporting {
                ProgressView()
            } else {
                Button("Export All Words", systemImage: "square.and.arrow.up") {
                    isExporting = true
                    let export = VocabularyExport(terms: store.entries.map(\.term))
                    Task {
                        do {
                            exportedFileURL = try await Task.detached { try export.writeFile() }.value
                        } catch {
                            isExporting = false
                        }
                    }
                }
            }
        }
    #else
        private var exportButton: some View {
            ShareLink(
                item: VocabularyExport(terms: store.entries.map(\.term)),
                preview: SharePreview(Text("Vocabulary"))
            ) {
                Label("Export All Words", systemImage: "square.and.arrow.up")
            }
        }
    #endif

    @ViewBuilder
    private var content: some View {
        if let loadError = store.loadError, store.entries.isEmpty {
            ContentUnavailableView(
                "Vocabulary Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if store.entries.isEmpty {
            ContentUnavailableView(
                "No Saved Words",
                systemImage: "bookmark",
                description: Text("Tap the bookmark on a translation result to save it here.")
            )
        } else if filteredEntries.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(filteredEntries) { entry in
                    NavigationLink {
                        VocabularyEntryDetailView(entry: entry)
                    } label: {
                        VocabularyRow(entry: entry)
                    }
                }
                .onDelete { offsets in
                    let entries = offsets.map { filteredEntries[$0] }
                    try? store.delete(entries)
                }
            }
        }
    }
}

private struct VocabularyRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: VocabularyEntry

    var body: some View {
        let colors = AppColors.palette(for: colorScheme)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.term)
                    .font(.headline)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(2)
                Text(VocabularyText.preview(of: entry.translation, term: entry.term))
                    .font(.subheadline)
                    .foregroundStyle(colors.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }
}

private struct VocabularyEntryDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: VocabularyEntry

    var body: some View {
        let colors = AppColors.palette(for: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.term)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .textSelection(.enabled)
                MarkdownContentView(text: entry.translation, preset: .compact)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle(entry.term)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        PasteboardHelper.copy(entry.translation)
                    }
                }
            }
    }
}

/// All saved terms as a `.txt` file, one term per line.
struct VocabularyExport: Transferable, Sendable {
    let terms: [String]

    var text: String {
        var seen = Set<String>()
        return terms
            .map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    func writeFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Vocabulary.txt")
        try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            try SentTransferredFile(export.writeFile())
        }
    }
}

#if os(iOS)
    /// Presents the system share sheet for `fileURL` and reports when it is on screen, which `ShareLink` cannot.
    private struct ActivitySheetPresenter: UIViewControllerRepresentable {
        @Binding var fileURL: URL?
        let onPresented: () -> Void

        func makeUIViewController(context: Context) -> UIViewController {
            UIViewController()
        }

        func updateUIViewController(_ controller: UIViewController, context: Context) {
            guard let fileURL, controller.presentedViewController == nil else { return }
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                self.fileURL = nil
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(x: controller.view.bounds.maxX - 44, y: 0, width: 44, height: 1)
                popover.permittedArrowDirections = .up
            }
            controller.present(activity, animated: true, completion: onPresented)
        }
    }
#endif

enum VocabularyText {
    /// First meaningful line of a Markdown translation, without markup or a line that only repeats the term.
    static func preview(of markdown: String, term: String = "") -> String {
        markdown
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"^(#+|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "*", with: "")
            }
            .first { line in
                !line.isEmpty && !line.allSatisfy { "-_#".contains($0) }
                    && line.compare(term, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame
            } ?? ""
    }
}
