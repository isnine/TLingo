//
//  VocabularySaveButton.swift
//  ShareCore
//

import SwiftUI

/// Bookmark toggle that adds a translation result to the vocabulary or removes it.
struct VocabularySaveButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = VocabularyStore.shared

    let draft: VocabularyDraft
    var iconSize: CGFloat = 13

    private var palette: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        let isSaved = store.contains(draft)
        Button {
            do {
                try store.toggle(draft)
            } catch {
                // The store logs failures; the icon simply keeps reflecting persisted state.
            }
        } label: {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: iconSize))
                // Accent marks the saved state only.
                .foregroundColor(isSaved ? palette.accent : palette.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(isSaved ? "Remove from Vocabulary" : "Save to Vocabulary")
        .accessibilityLabel(isSaved ? "Remove from Vocabulary" : "Save to Vocabulary")
        .accessibilityIdentifier("vocabulary_save_button")
        .onAppear { store.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reload()
            }
        }
    }
}
