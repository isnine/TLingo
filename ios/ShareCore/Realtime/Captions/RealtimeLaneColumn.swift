#if os(macOS)
    import SwiftUI

    struct RealtimeLaneColumn: View {
        @ObservedObject var store: RealtimeSessionStore
        let configuration: RealtimeLaneConfiguration
        let snapshot: RealtimeLaneSnapshot?
        let colors: AppColors.Palette
        let minimumWidth: CGFloat
        let sourceLanguage: SourceLanguageOption

        private var phase: RealtimeLaneSnapshot.Phase {
            snapshot?.phase ?? .ready
        }

        var body: some View {
            VStack(spacing: 0) {
                RealtimeLaneHeader(
                    store: store,
                    configuration: configuration,
                    snapshot: snapshot,
                    colors: colors,
                    sourceLanguage: sourceLanguage,
                    phaseTitle: phaseTitle,
                    phaseColor: phaseColor
                )
                Divider()
                RealtimeLaneTranscript(
                    store: store,
                    configurationID: configuration.id,
                    snapshot: snapshot,
                    colors: colors,
                    phaseTitle: phaseTitle
                )
            }
            .frame(minWidth: minimumWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(colors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(colors.divider, lineWidth: 1)
            }
        }

        private var phaseTitle: String {
            switch phase {
            case .ready:
                return String(localized: "Ready")
            case .loading:
                return String(localized: "Loading")
            case .listening:
                return String(localized: "Listening")
            case .recognizing:
                return String(localized: "Recognizing")
            case .translating:
                return String(localized: "Translating")
            case .paused:
                return String(localized: "Paused")
            case .stopped:
                return String(localized: "Stopped")
            case .failed:
                return String(localized: "Error")
            }
        }

        private var phaseColor: Color {
            switch phase {
            case .ready, .stopped:
                return colors.textSecondary
            case .loading, .translating:
                return colors.accent
            case .listening, .recognizing:
                return colors.success
            case .paused:
                return .yellow
            case .failed:
                return colors.error
            }
        }
    }
#endif
