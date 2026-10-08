//
//  VocabularySaveButton.swift
//  ShareCore
//

import SwiftUI

/// Bookmark toggle that adds a translation result to the vocabulary or removes it.
struct VocabularySaveButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var store = VocabularyStore.shared

    let draft: VocabularyDraft
    var iconSize: CGFloat = 13

    var body: some View {
        let isSaved = store.contains(draft)
        Button {
            do {
                if isSaved {
                    try store.remove(draft)
                } else {
                    try store.save(draft)
                }
            } catch {
                // The store logs failures; the icon simply keeps reflecting persisted state.
            }
        } label: {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: iconSize))
                .foregroundColor(AppColors.palette(for: colorScheme).accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isSaved ? "Remove from Vocabulary" : "Save to Vocabulary")
        .accessibilityLabel(isSaved ? "Remove from Vocabulary" : "Save to Vocabulary")
        .accessibilityIdentifier("vocabulary_save_button")
    }
}
