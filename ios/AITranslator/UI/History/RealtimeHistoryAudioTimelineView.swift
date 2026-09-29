import ShareCore
import SwiftUI

struct RealtimeHistoryAudioTimelineView: View {
    let recordings: [RealtimeHistoryAudioRecording]
    @Binding var selectedSource: RealtimeHistoryAudioSource
    @Binding var playbackTime: TimeInterval
    let onScrub: (TimeInterval) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var audioPlayer = RealtimeHistoryAudioPlayer()

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var selectedRecording: RealtimeHistoryAudioRecording? {
        recordings.first { $0.source == selectedSource }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    audioPlayer.togglePlayback()
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(selectedRecording == nil || audioPlayer.duration <= 0)
                .accessibilityLabel(audioPlayer.isPlaying ? "Pause" : "Play")

                Text(audioPlayer.currentTime.clockLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 42, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { audioPlayer.currentTime },
                        set: {
                            audioPlayer.seek(to: $0)
                            onScrub($0)
                        }
                    ),
                    in: 0 ... max(audioPlayer.duration, 0.01)
                )
                .disabled(audioPlayer.duration <= 0)

                Text(audioPlayer.duration.clockLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.textSecondary)
                    .frame(width: 42, alignment: .leading)

                if recordings.count > 1 {
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
                        Image(systemName: selectedSource.systemImage)
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .help(selectedSource.title)
                    .accessibilityLabel("Audio Source")
                }
            }

            if let errorMessage = audioPlayer.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(colors.textSecondary)
            }
        }
        .task(id: selectedRecording?.id) {
            guard let selectedRecording else {
                audioPlayer.stop()
                return
            }
            await audioPlayer.load(recording: selectedRecording)
        }
        .onReceive(audioPlayer.$currentTime) { playbackTime = $0 }
        .onChange(of: playbackTime) { _, newValue in
            guard abs(newValue - audioPlayer.currentTime) > 0.15 else { return }
            audioPlayer.seek(to: newValue)
        }
        .onDisappear {
            audioPlayer.stop()
        }
    }
}
