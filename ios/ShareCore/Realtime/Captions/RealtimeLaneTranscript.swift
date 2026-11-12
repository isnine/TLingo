#if os(macOS)
    import AppKit
    import SwiftUI

    struct RealtimeLaneTranscript: View {
        @ObservedObject private var preferences = AppPreferences.shared
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
            .background(appearance.captionBackgroundColor(fallback: colors.cardBackground))
        }

        private var appearance: RealtimeCaptionAppearance {
            preferences.realtimeCaptionAppearance
        }

        private var captionStyle: RealtimeCaptionScrollView.Style {
            let sizeScale = CGFloat(appearance.textSize / 22)
            let spacingScale = CGFloat(appearance.spacing.scale)

            return RealtimeCaptionScrollView.Style(
                sourceFont: RealtimeCaptionScrollView.Style.font(
                    size: 15 * sizeScale,
                    weight: .medium,
                    design: appearance.fontDesign,
                    defaultDesign: .rounded
                ),
                translationFont: RealtimeCaptionScrollView.Style.font(
                    size: 20 * sizeScale,
                    weight: .semibold,
                    design: appearance.fontDesign,
                    defaultDesign: .rounded
                ),
                sourceColor: NSColor(appearance.sourceTextColor(fallback: colors.textSecondary)),
                translationColor: NSColor(appearance.translationTextColor(fallback: colors.textPrimary)),
                pendingColor: NSColor(colors.accent),
                sourceLineSpacing: 3 * spacingScale,
                translationLineSpacing: 5 * spacingScale,
                lineGap: 16 * spacingScale,
                horizontalPadding: 18,
                verticalPadding: 18,
                alignsShortContentToBottom: true,
                isSelectable: true,
                sourcePendingColor: appearance.sourceColor.map { NSColor($0.color).withAlphaComponent(0.85) },
                translationPendingColor: appearance.translationColor.map { NSColor($0.color).withAlphaComponent(0.85) }
            )
        }

        private var captionLines: [RealtimeCaptionLine] {
            snapshot?.captionLines ?? []
        }
    }
#endif
