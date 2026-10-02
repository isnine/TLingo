#if os(macOS)
    import ShareCore
    import SwiftUI

    struct RealtimeProgressOverlay: View {
        @Environment(\.colorScheme) private var colorScheme
        @ObservedObject var preferences: AppPreferences
        let isStopping: Bool
        let statusText: String

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        var body: some View {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)

                    VStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(colors.textPrimary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(width: 320)
                .tlingoGlassSurface(.panel, cornerRadius: TLingoRadius.large)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.16), radius: 22, x: 0, y: 10)
            }
            .transition(.opacity)
        }

        private var title: String {
            isStopping ? statusText : String(localized: "Starting realtime translation...")
        }

        private var detail: String {
            isStopping
                ? String(localized: "Saving transcript and stopping audio capture.")
                : String(localized: "Connecting audio and realtime service. This can take a few seconds.")
        }
    }
#endif
