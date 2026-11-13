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
