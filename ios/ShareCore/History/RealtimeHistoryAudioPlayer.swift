import AVFoundation
import Combine
import Foundation

@MainActor
public final class RealtimeHistoryAudioPlayer: ObservableObject {
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var activatedAudioSession = false

    public init() {}

    public func load(recording: RealtimeHistoryAudioRecording) async {
        stop()
        errorMessage = nil
        duration = RealtimeHistoryAudioTimeline.duration(for: recording)
        do {
            let composition = try await RealtimeHistoryAudioTimeline.composition(for: recording)
            guard !Task.isCancelled else { return }
            cleanupObservers()
            let item = AVPlayerItem(asset: composition)
            let player = AVPlayer(playerItem: item)
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated {
                    self?.currentTime = max(0, time.seconds)
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentTime = self.duration
                    self.isPlaying = false
                    self.deactivateAudioSession()
                }
            }
            self.player = player
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        do {
            try activateAudioSession()
            if currentTime >= duration {
                seek(to: 0)
            }
            player.play()
            isPlaying = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func seek(to time: TimeInterval) {
        currentTime = min(max(0, time), duration)
        player?.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    public func stop() {
        player?.pause()
        cleanupObservers()
        player = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        deactivateAudioSession()
    }

    private func cleanupObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        timeObserver = nil
        endObserver = nil
    }

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func activateAudioSession() throws {
        #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            activatedAudioSession = true
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
            guard activatedAudioSession else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedAudioSession = false
        #endif
    }
}
