#if os(macOS) || os(iOS)
    import SwiftUI

    public struct RealtimeCaptionModeMenu: View {
        @ObservedObject var store: RealtimeSessionStore
        private let onAppearance: () -> Void

        public init(store: RealtimeSessionStore, onAppearance: @escaping () -> Void) {
            self.store = store
            self.onAppearance = onAppearance
        }

        public var body: some View {
            Menu {
                RealtimeCaptionModePicker(store: store)
                Divider()
                Button("Caption Appearance…", systemImage: "textformat.size", action: onAppearance)
            } label: {
                #if os(iOS)
                    HStack(spacing: 4) {
                        Text(store.resolvedCaptionDisplayMode.title)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                #else
                    Text(store.resolvedCaptionDisplayMode.title)
                #endif
            }
            .accessibilityLabel(Text("Caption Display"))
            .accessibilityValue(Text(store.resolvedCaptionDisplayMode.title))
            .accessibilityIdentifier("realtime_caption_mode_menu")
        }
    }
#endif
