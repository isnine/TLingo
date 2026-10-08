//
//  VocabularyView.swift
//  ShareCore
//

import SwiftUI

/// Saved terms with search, deletion and a flashcard review session. Hosts provide the navigation container.
public struct VocabularyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = VocabularyStore.shared
    @State private var searchText = ""
    @State private var reviewSession: ReviewSession?

    private struct ReviewSession: Identifiable {
        let id = UUID()
        let queue: [VocabularyEntry]
    }

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
                    Button("Review", systemImage: "rectangle.on.rectangle.angled") {
                        reviewSession = ReviewSession(queue: store.reviewQueue())
                    }
                    .disabled(store.entries.isEmpty)
                    .accessibilityIdentifier("vocabulary_review_button")
                }
            }
            .sheet(item: $reviewSession) { session in
                VocabularyReviewView(queue: session.queue) { reviewSession = nil }
                #if os(macOS)
                    .frame(minWidth: 480, minHeight: 520)
                #endif
            }
            .onAppear { store.reload() }
    }

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
            if entry.isLearned {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(colors.accent)
                    .accessibilityLabel("Learned")
            }
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
                Text(VocabularyText.reviewSummary(for: entry))
                    .font(.footnote)
                    .foregroundStyle(colors.textSecondary)
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

/// One pass through a fixed queue: reveal the answer, then grade it.
struct VocabularyReviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = VocabularyStore.shared
    let queue: [VocabularyEntry]
    let onClose: () -> Void

    @State private var index = 0
    @State private var isRevealed = false
    @State private var rememberedCount = 0

    var body: some View {
        let colors = AppColors.palette(for: colorScheme)
        NavigationStack {
            VStack(spacing: 20) {
                if index < queue.count {
                    card(for: queue[index], colors: colors)
                    controls
                } else {
                    ContentUnavailableView(
                        "Review Complete",
                        systemImage: "checkmark.circle",
                        description: Text("Remembered \(rememberedCount) of \(queue.count).")
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.background.ignoresSafeArea())
            .navigationTitle(index < queue.count ? Text("\(index + 1) of \(queue.count)") : Text("Review"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: onClose)
                    }
                }
        }
    }

    private func card(for entry: VocabularyEntry, colors: AppColorPalette) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(entry.term)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                if isRevealed {
                    Divider()
                    MarkdownContentView(text: entry.translation, preset: .compact)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: TLingoRadius.medium, style: .continuous)
                .fill(colors.cardBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture { isRevealed = true }
    }

    @ViewBuilder
    private var controls: some View {
        if isRevealed {
            HStack(spacing: 12) {
                Button {
                    grade(remembered: false)
                } label: {
                    Label("Forgot", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("vocabulary_review_forgot")

                Button {
                    grade(remembered: true)
                } label: {
                    Label("Remembered", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("vocabulary_review_remembered")
            }
            .controlSize(.large)
        } else {
            Button {
                isRevealed = true
            } label: {
                Text("Show Answer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityIdentifier("vocabulary_review_reveal")
        }
    }

    private func grade(remembered: Bool) {
        try? store.recordReview(queue[index], remembered: remembered)
        if remembered {
            rememberedCount += 1
        }
        isRevealed = false
        index += 1
    }
}

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

    static func reviewSummary(for entry: VocabularyEntry) -> String {
        guard let lastReviewedAt = entry.lastReviewedAt else {
            return String(localized: "Not reviewed yet")
        }
        let date = lastReviewedAt.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "Reviewed \(entry.reviewCount) times · last \(date)")
    }
}
