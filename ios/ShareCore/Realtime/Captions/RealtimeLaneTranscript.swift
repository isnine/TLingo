#if os(macOS)
    import AppKit
    import SwiftUI

    struct RealtimeLaneTranscript: View {
        @ObservedObject var store: RealtimeSessionStore
        let snapshot: RealtimeLaneSnapshot?
        let colors: AppColors.Palette
        let phaseTitle: String

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if let error = snapshot?.errorMessage, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.body)
                        .foregroundStyle(colors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.horizontal, .top], 18)
                }

                ZStack {
                    RealtimeCaptionScrollView(lines: captionLines, style: captionStyle)

                    if captionLines.isEmpty {
                        ContentUnavailableView {
                            Label(phaseTitle, systemImage: "waveform")
                        } description: {
                            Text(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: store.isRunning))
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        /// Matches the iOS caption hierarchy, scaled down for side-by-side lanes.
        private var captionStyle: RealtimeCaptionScrollView.Style {
            RealtimeCaptionScrollView.Style(
                sourceFont: RealtimeCaptionScrollView.Style.roundedFont(size: 15, weight: .medium),
                translationFont: RealtimeCaptionScrollView.Style.roundedFont(size: 20, weight: .semibold),
                sourceColor: NSColor(colors.textSecondary),
                translationColor: NSColor(colors.textPrimary),
                pendingColor: NSColor(colors.accent),
                sourceLineSpacing: 3,
                translationLineSpacing: 5,
                lineGap: 16,
                horizontalPadding: 18,
                verticalPadding: 18,
                alignsShortContentToBottom: true,
                isSelectable: true
            )
        }

        private var captionLines: [RealtimeCaptionLine] {
            snapshot?.captionLines ?? []
        }
    }
#endif
