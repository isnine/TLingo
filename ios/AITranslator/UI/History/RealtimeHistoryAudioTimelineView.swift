#if os(macOS)
    import AVFoundation
    import Combine
    import ShareCore
    import SwiftUI

    @MainActor
    private final class RealtimeHistoryAudioPlayer: ObservableObject {
        @Published private(set) var currentTime: TimeInterval = 0
        @Published private(set) var duration: TimeInterval = 0
        @Published private(set) var isPlaying = false
        @Published private(set) var errorMessage: String?

        private var player: AVPlayer?
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?

        func load(recording: RealtimeHistoryAudioRecording) async {
            stop()
            errorMessage = nil
            duration = RealtimeHistoryAudioTimeline.duration(for: recording)
            do {
                let composition = try await RealtimeHistoryAudioTimeline.composition(for: recording)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: composition)
                let player = AVPlayer(playerItem: item)
                timeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                    queue: .main
                ) { [weak self] time in
                    Task { @MainActor in
                        self?.currentTime = max(0, time.seconds)
                    }
                }
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.isPlaying = false
                    }
                }
                self.player = player
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func togglePlayback() {
            guard let player else { return }
            if isPlaying {
                player.pause()
            } else {
                if currentTime >= duration {
                    seek(to: 0)
                }
                player.play()
            }
            isPlaying.toggle()
        }

        func seek(to time: TimeInterval) {
            currentTime = min(max(0, time), duration)
            player?.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        func stop() {
            player?.pause()
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            player = nil
            timeObserver = nil
            endObserver = nil
            currentTime = 0
            isPlaying = false
        }

        deinit {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }

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
#endif
