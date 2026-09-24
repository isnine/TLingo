//
//  SpeechRecognitionService.swift
//  ShareCore
//

import AVFoundation
import Combine
import Foundation
#if canImport(UIKit)
    import UIKit
#endif

public enum SpeechRecognitionError: Error, LocalizedError {
    case permissionDenied
    case audioEngineError(String)
    case transcriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Microphone permission was denied")
        case let .audioEngineError(detail):
            return String(localized: "Audio engine error: \(detail)")
        case let .transcriptionFailed(detail):
            return String(localized: "Transcription failed: \(detail)")
        }
    }
}

public final class SpeechRecognitionService: NSObject, ObservableObject {
    public enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case processing
    }

    @Published public private(set) var transcript: String = ""
    @Published public private(set) var state: State = .idle
    @Published public private(set) var error: SpeechRecognitionError?
    @Published public private(set) var recordingDuration: TimeInterval = 0

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private var backgroundTime: Date?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionGeneration = UUID()
    private let transcribe: @Sendable (URL) async throws -> String

    public init(
        transcribe: @escaping @Sendable (URL) async throws -> String = {
            try await WhisperService.shared.transcribe(audioFileURL: $0)
        }
    ) {
        self.transcribe = transcribe
        super.init()
        registerForAppLifecycle()
    }

    deinit {
        transcriptionTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Authorization

    @MainActor
    public func requestAuthorization() async -> Bool {
        #if os(iOS)
            let micStatus = await AVAudioApplication.requestRecordPermission()
            guard micStatus else {
                error = .permissionDenied
                return false
            }
        #endif
        return true
    }

    // MARK: - Recording

    @MainActor
    public func startRecording() async {
        guard state == .idle else { return }

        invalidateTranscription()
        state = .preparing
        transcript = ""
        error = nil
        recordingDuration = 0

        do {
            // Yield so SwiftUI can render the preparing state
            await Task.yield()

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            audioFileURL = tempURL

            #if os(iOS)
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: recordingFormat.sampleRate,
                AVNumberOfChannelsKey: Int(recordingFormat.channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]

            audioFile = try AVAudioFile(forWriting: tempURL, settings: outputSettings)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                try? self?.audioFile?.write(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            state = .recording
            recordingStartTime = Date()
            startDurationTimer()
        } catch {
            self.error = .audioEngineError(error.localizedDescription)
            state = .idle
            cleanupAudioFile()
        }
    }

    @MainActor
    public func stopRecording() {
        guard state == .recording || state == .paused else { return }
        state = .processing
        stopDurationTimer()
        finishRecording()

        guard let audioFileURL else {
            state = .idle
            return
        }

        beginTranscription(audioFileURL: audioFileURL)
    }

    @MainActor
    public func cancelRecording() {
        stopDurationTimer()
        if state == .recording || state == .paused {
            finishRecording()
        }
        invalidateTranscription()
        state = .idle
        transcript = ""
        cleanupAudioFile()
    }

    // MARK: - Private

    @MainActor
    private func finishRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil

        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    @MainActor
    func beginTranscription(audioFileURL: URL) {
        invalidateTranscription()
        let generation = UUID()
        transcriptionGeneration = generation
        self.audioFileURL = audioFileURL
        state = .processing

        let transcribe = transcribe
        transcriptionTask = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = try .success(await transcribe(audioFileURL))
            } catch {
                result = .failure(error)
            }

            guard let self else {
                Self.removeAudioFile(at: audioFileURL)
                return
            }
            finishTranscription(result, audioFileURL: audioFileURL, generation: generation)
        }
    }

    @MainActor
    private func finishTranscription(
        _ result: Result<String, Error>,
        audioFileURL: URL,
        generation: UUID
    ) {
        guard generation == transcriptionGeneration else {
            Self.removeAudioFile(at: audioFileURL)
            return
        }

        defer {
            state = .idle
            transcriptionTask = nil
            if self.audioFileURL == audioFileURL {
                self.audioFileURL = nil
            }
            Self.removeAudioFile(at: audioFileURL)
        }

        switch result {
        case let .success(text):
            transcript = text
        case let .failure(error):
            self.error = .transcriptionFailed(error.localizedDescription)
        }
    }

    @MainActor
    private func invalidateTranscription() {
        transcriptionGeneration = UUID()
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    @MainActor
    private func cleanupAudioFile() {
        guard let url = audioFileURL else { return }
        Self.removeAudioFile(at: url)
        audioFileURL = nil
    }

    private static func removeAudioFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            Task { @MainActor in
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartTime = nil
    }

    // MARK: - App Lifecycle

    private func registerForAppLifecycle() {
        #if os(iOS)
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidEnterBackground),
                name: UIApplication.didEnterBackgroundNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(appWillEnterForeground),
                name: UIApplication.willEnterForegroundNotification, object: nil
            )
        #endif
    }

    @objc private func appDidEnterBackground() {
        guard state == .recording else { return }
        backgroundTime = Date()
        Task { @MainActor in
            state = .paused
            audioEngine.pause()
        }
    }

    @objc private func appWillEnterForeground() {
        guard state == .paused else { return }
        let elapsed = backgroundTime.map { Date().timeIntervalSince($0) } ?? .infinity
        Task { @MainActor in
            if elapsed > 30 {
                cancelRecording()
            } else {
                try? audioEngine.start()
                state = .recording
            }
            backgroundTime = nil
        }
    }
}
