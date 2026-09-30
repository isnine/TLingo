#if os(macOS)
    import ShareCore
    import SwiftUI

    /// Dismissible bubble showing the latest recognition and translation latency per lane.
    struct RealtimeLatencyBubble: View {
        @Environment(\.colorScheme) private var colorScheme
        let lanes: [(title: String, performsTranslation: Bool, latency: RealtimeLaneLatency)]
        let onClose: () -> Void

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                        VStack(alignment: .leading, spacing: 2) {
                            if lanes.count > 1 {
                                Text(lane.title)
                                    .font(.caption2)
                                    .foregroundStyle(colors.textSecondary)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 10) {
                                metric("Recognition", milliseconds: lane.latency.recognitionMilliseconds)
                                if lane.performsTranslation {
                                    metric("Translation", milliseconds: lane.latency.translationMilliseconds)
                                }
                            }
                        }
                    }
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Hide latency")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(colors.divider, lineWidth: 0.5))
        }

        private func metric(_ title: LocalizedStringKey, milliseconds: Int?) -> some View {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(colors.textSecondary)
                Text(milliseconds.map { "\($0) ms" } ?? "— ms")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }
#endif
