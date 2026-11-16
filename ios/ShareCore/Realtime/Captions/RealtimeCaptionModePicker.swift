import SwiftUI

public struct RealtimeCaptionModePicker: View {
    @ObservedObject var store: RealtimeSessionStore

    public init(store: RealtimeSessionStore) {
        self.store = store
    }

    public var body: some View {
        Picker("Display", selection: Binding(
            get: { store.resolvedCaptionDisplayMode },
            set: { store.captionDisplayMode = $0 }
        )) {
            ForEach([RealtimeCaptionDisplayMode.bilingual, .translationOnly, .sourceOnly]) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .disabled(!store.captionTranslationAvailable)
        .accessibilityIdentifier("realtime_caption_mode_picker")
    }
}

public struct RealtimeSentenceBySentenceToggle: View {
    @ObservedObject var store: RealtimeSessionStore
    @ObservedObject var preferences: AppPreferences

    public init(store: RealtimeSessionStore, preferences: AppPreferences) {
        self.store = store
        self.preferences = preferences
    }

    public var body: some View {
        Toggle("Sentence by Sentence", isOn: Binding(
            get: { preferences.realtimeSentenceBySentenceEnabled },
            set: { preferences.setRealtimeSentenceBySentenceEnabled($0) }
        ))
        .disabled(store.resolvedCaptionDisplayMode != .bilingual)
    }
}
