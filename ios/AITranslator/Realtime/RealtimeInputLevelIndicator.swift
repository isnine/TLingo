#if os(iOS)
    import ShareCore
    import SwiftUI

    /// Bars that follow the live microphone level, so users can see whether they are being heard.
    struct RealtimeInputLevelIndicator: View {
        @ObservedObject var level: RealtimeInputLevel
        var isActive: Bool
        var tint: Color
        var barWidth: CGFloat = 6
        var maxHeight: CGFloat = 72

        /// Per-bar scale so the shape reads as a waveform rather than a single block.
        private static let barWeights: [Double] = [0.35, 0.55, 0.75, 0.9, 1, 0.9, 0.75, 0.55, 0.35]

        var body: some View {
            // Silence keeps the bars still, so there is nothing to animate.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive || level.fraction == 0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: barWidth * 0.8) {
                    ForEach(Self.barWeights.indices, id: \.self) { index in
                        Capsule()
                            .fill(tint)
                            .frame(width: barWidth, height: barHeight(index: index, time: time))
                    }
                }
                .frame(height: maxHeight)
            }
            .opacity(isActive ? 1 : 0.4)
            .accessibilityHidden(true)
        }

        private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
            let fraction = isActive ? level.fraction : 0
            let jitter = 0.7 + 0.3 * sin(time * 11 + Double(index) * 1.7)
            return barWidth + (maxHeight - barWidth) * fraction * Self.barWeights[index] * jitter
        }
    }

    /// Hint shown when speech stays too faint to recognize.
    struct RealtimeFaintSpeechHint: View {
        @ObservedObject var level: RealtimeInputLevel
        var isActive: Bool
        var color: Color

        var body: some View {
            Group {
                if isActive, level.isFaint {
                    Label("Speech is faint. Move closer to the microphone.", systemImage: "mic.badge.xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(color)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: isActive && level.isFaint)
        }
    }
#endif
