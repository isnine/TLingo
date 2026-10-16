import ShareCore
import SwiftUI

struct RealtimeHistoryAudioTimelineView: View {
    let recordings: [RealtimeHistoryAudioRecording]
    @Binding var selectedSource: RealtimeHistoryAudioSource
    @Binding var playbackTime: TimeInterval
    @Binding var isPlaying: Bool
    let onScrub: (TimeInterval) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var audioPlayer = RealtimeHistoryAudioPlayer()
    @State private var waveformLevels: [Float]?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var selectedRecording: RealtimeHistoryAudioRecording? {
        recordings.first { $0.source == selectedSource }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    audioPlayer.togglePlayback()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(colors.onAccent)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(colors.accentFill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(selectedRecording == nil || audioPlayer.duration <= 0)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

                HStack(spacing: 4) {
                    Text(audioPlayer.currentTime.clockLabel)
                        .foregroundStyle(colors.textPrimary)
                    Text(verbatim: "/")
                        .foregroundStyle(colors.textSecondary.opacity(0.6))
                    Text(audioPlayer.duration.clockLabel)
                        .foregroundStyle(colors.textSecondary)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()

                Spacer(minLength: 0)

                if recordings.count > 1 {
                    sourceMenu
                }
            }

            RealtimeHistoryWaveformView(
                levels: waveformLevels,
                duration: audioPlayer.duration,
                currentTime: audioPlayer.currentTime,
                onSeek: { time in
                    audioPlayer.seek(to: time)
                    onScrub(time)
                }
            )
            .frame(height: 44)
            .disabled(audioPlayer.duration <= 0)

            if let errorMessage = audioPlayer.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .task(id: selectedRecording?.id) {
            guard let selectedRecording else {
                audioPlayer.stop()
                waveformLevels = nil
                return
            }
            waveformLevels = RealtimeHistoryWaveformCache.levels[selectedRecording.id]
            await audioPlayer.load(recording: selectedRecording)
            guard waveformLevels == nil else { return }
            if let levels = try? await RealtimeHistoryAudioTimeline.waveformLevels(
                for: selectedRecording,
                bucketCount: RealtimeHistoryWaveformCache.bucketCount
            ), !Task.isCancelled {
                RealtimeHistoryWaveformCache.levels[selectedRecording.id] = levels
                waveformLevels = levels
            }
        }
        .onReceive(audioPlayer.$currentTime) { playbackTime = $0 }
        .onReceive(audioPlayer.$isPlaying) { isPlaying = $0 }
        .onChange(of: playbackTime) { _, newValue in
            guard abs(newValue - audioPlayer.currentTime) > 0.15 else { return }
            audioPlayer.seek(to: newValue)
        }
        .onDisappear {
            audioPlayer.stop()
        }
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(recordings, id: \.source) { recording in
                Button {
                    selectedSource = recording.source
                } label: {
                    Label(
                        recording.source.title,
                        systemImage: recording.source == selectedSource
                            ? "checkmark"
                            : recording.source.systemImage
                    )
                }
            }
        } label: {
            Label(selectedSource.title, systemImage: selectedSource.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(colors.chipSecondaryBackground)
                .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(selectedSource.title)
        .accessibilityLabel("Audio Source")
    }
}

@MainActor
private enum RealtimeHistoryWaveformCache {
    static let bucketCount = 1200
    static var levels: [UUID: [Float]] = [:]
}

/// Bar waveform of the recording. Played audio is tinted with the accent color; clicking or
/// dragging anywhere seeks there.
private struct RealtimeHistoryWaveformView: View {
    let levels: [Float]?
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hoverX: CGFloat?

    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, width > 0, duration > 0 else { return }
                        onSeek(min(max(0, value.location.x / width), 1) * duration)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    hoverX = location.x
                case .ended:
                    hoverX = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Seek")
        .accessibilityValue(currentTime.clockLabel)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(duration, currentTime + 5))
            case .decrement: onSeek(max(0, currentTime - 5))
            @unknown default: break
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let step = Self.barWidth + Self.barSpacing
        let barCount = max(1, Int((size.width + Self.barSpacing) / step))
        let progressX = duration > 0 ? size.width * min(1, currentTime / duration) : 0
        let played = colors.accent
        let unplayed = colors.textSecondary.opacity(0.35)
        let hovered = colors.accent.opacity(0.45)

        for index in 0 ..< barCount {
            let x = CGFloat(index) * step
            let level = level(forBar: index, of: barCount)
            let height = max(2, CGFloat(level) * size.height)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
            let color: Color
            if x + Self.barWidth / 2 <= progressX {
                color = played
            } else if let hoverX, isEnabled, x <= hoverX {
                color = hovered
            } else {
                color = unplayed
            }
            context.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(color))
        }
    }

    private func level(forBar index: Int, of barCount: Int) -> Float {
        guard let levels, !levels.isEmpty else { return 0 }
        let lower = index * levels.count / barCount
        let upper = max(lower + 1, (index + 1) * levels.count / barCount)
        return levels[lower ..< min(upper, levels.count)].max() ?? 0
    }
}
